//! Certificate validator tests

use super::CertificateValidator;
use crate::{
    state_sync::{AtomicRound, CertificateManagerCommand},
    ConsensusBus,
};
use rayls_consensus_primary::test_utils::make_optimal_signed_certificates;
use rayls_infrastructure_storage::mem_db::MemDatabase;
use rayls_infrastructure_types::{
    BlsSignature, Certificate, Hash as _, RaylsReceiver as _, RaylsSender, Round,
    SignatureVerificationState, TaskManager,
};
use rayls_testing_test_utils_committee::CommitteeFixture;
use std::collections::BTreeSet;

struct TestTypes<DB = MemDatabase> {
    /// The CertificateValidator
    validator: CertificateValidator<DB>,
    /// The consensus bus.
    cb: ConsensusBus,
    /// The committee fixture.
    fixture: CommitteeFixture<DB>,
    /// Task manager controlling spawned tasks.
    task_manager: TaskManager,
}

fn create_test_types() -> TestTypes<MemDatabase> {
    create_test_types_with_gc(0)
}

fn create_test_types_with_gc(gc_round_val: Round) -> TestTypes<MemDatabase> {
    let fixture = CommitteeFixture::builder(MemDatabase::default).randomize_ports(true).build();
    let cb = ConsensusBus::new();
    let primary = fixture.authorities().last().unwrap();

    // for validator
    let config = primary.consensus_config();
    let gc_round = AtomicRound::new(gc_round_val);
    let highest_processed_round = AtomicRound::new(0);
    let highest_received_round = AtomicRound::new(0);

    let task_manager = TaskManager::default();
    let validator = CertificateValidator::new(
        config,
        cb.clone(),
        gc_round,
        highest_processed_round,
        highest_received_round,
        task_manager.get_spawner(),
    );

    TestTypes { validator, cb, fixture, task_manager }
}

/// A fetched batch that straddles gc must not fail wholesale. Below-gc (`TooOld`) certs are dropped
/// and the still-needed above-gc certs are verified and forwarded; before the fix, one `TooOld`
/// cert failed the entire fetch, discarding the valid parents and wedging catch-up in an endless
/// refetch loop (the cert DAG can never rebuild because every fetch straddles gc once the
/// acceptance floor races ahead during catch-up).
#[tokio::test]
async fn fetched_batch_straddling_gc_drops_too_old_and_keeps_rest() -> eyre::Result<()> {
    const GC: Round = 30;
    let TestTypes { validator, cb, fixture, task_manager: _task_manager } =
        create_test_types_with_gc(GC);

    // Drain the certificate-manager channel: forwarding awaits the reply, and assert no below-gc
    // cert is ever forwarded.
    let mut certificate_manager_rx = cb.certificate_manager().subscribe();
    let drainer = tokio::task::spawn(async move {
        while let Some(command) = certificate_manager_rx.recv().await {
            if let CertificateManagerCommand::ProcessVerifiedCertificates { certificates, reply } =
                command
            {
                for cert in &certificates {
                    assert!(cert.is_verified(), "forwarded cert must be verified");
                    assert!(cert.round() >= GC, "below-gc cert forwarded: round {}", cert.round());
                }
                let _ = reply.send(Ok(()));
            }
        }
    });

    let committee = fixture.committee();
    let genesis =
        Certificate::genesis(&committee).iter().map(|x| x.digest()).collect::<BTreeSet<_>>();
    let keys = fixture.authorities().map(|a| (a.id(), a.keypair().copy())).collect::<Vec<_>>();
    let (certificates, _next_parents) =
        make_optimal_signed_certificates(1..=60, &genesis, &committee, &keys);
    let batch = certificates.into_iter().collect::<Vec<_>>();

    // sanity: the batch genuinely straddles gc
    assert!(batch.iter().any(|c| c.round() < GC), "batch must include below-gc certs");
    assert!(batch.iter().any(|c| c.round() >= GC), "batch must include above-gc certs");

    // Before the fix: a below-gc (`TooOld`) cert fails the whole batch -> Err here.
    // After the fix: below-gc certs are dropped, the above-gc certs verify -> Ok.
    validator.process_fetched_certificates_in_parallel(batch).await?;

    drainer.abort();
    Ok(())
}

#[tokio::test]
async fn test_certificates_verified() -> eyre::Result<()> {
    let TestTypes { validator, cb, fixture, task_manager: _task_manager } = create_test_types();

    // receive verified certificates
    let mut certificate_manager_rx = cb.certificate_manager().subscribe();

    // create 3 certs
    // NOTE: test types uses the last authority
    let certs: Vec<_> = fixture.headers().iter().take(3).map(|h| fixture.certificate(h)).collect();
    let cloned_certs = certs.clone();

    // spawn task to receive processed certificates
    let cert_manager = tokio::task::spawn(async move {
        // ensure certs are verified and sent to certificate manager
        for cert in cloned_certs {
            // receive cert
            let command = certificate_manager_rx.recv().await.unwrap();
            let received = match command {
                CertificateManagerCommand::ProcessVerifiedCertificates { certificates, .. } => {
                    certificates
                }
                other => {
                    panic!("unexpected command: {other:?}");
                }
            };
            assert_eq!(*received, vec![cert]);
            assert!(received[0].is_verified());
        }
    });

    // assert unverified certificates and process
    for cert in certs {
        assert!(!cert.is_verified());
        // try to accept - ignore err for dropped oneshot
        let _ = validator.process_peer_certificate(cert).await;
    }

    assert!(cert_manager.await.is_ok());

    Ok(())
}

#[tokio::test]
async fn test_process_fetched_certificates_in_parallel() -> eyre::Result<()> {
    let TestTypes { validator, cb, fixture, task_manager: _task_manager } = create_test_types();

    // receive verified certificates
    let mut certificate_manager_rx = cb.certificate_manager().subscribe();
    let committee = fixture.committee();

    // NOTE: test types uses the last authority
    // create some certificates in a complete DAG form
    let genesis_certs = Certificate::genesis(&committee);
    let genesis = genesis_certs.iter().map(|x| x.digest()).collect::<BTreeSet<_>>();

    let keys = fixture.authorities().map(|a| (a.id(), a.keypair().copy())).collect::<Vec<_>>();
    let (certificates, _next_parents) =
        make_optimal_signed_certificates(1..=60, &genesis, &committee, &keys);

    let unverified_certificates = certificates.into_iter().collect::<Vec<_>>();

    const VERIFICATION_ROUND: Round = 50;
    const LEAF_ROUND: Round = 60;

    let _task = tokio::task::spawn(async move {
        loop {
            // receive cert
            let command = certificate_manager_rx.recv().await.unwrap();
            let received = match command {
                CertificateManagerCommand::ProcessVerifiedCertificates { certificates, reply } => {
                    // return ok
                    let _ = reply.send(Ok(()));
                    certificates
                }
                other => {
                    panic!("unexpected command: {other:?}");
                }
            };

            // ensure verified
            for cert in received {
                assert!(cert.is_verified());
            }
        }
    });

    // assert unverified certificates and process
    for cert in &unverified_certificates {
        assert!(!cert.is_verified());
    }

    // test success
    assert!(validator
        .process_fetched_certificates_in_parallel(unverified_certificates.clone())
        .await
        .is_ok());

    // Fail to verify a batch of certificates with good signatures for leaves,
    // but bad signatures at other rounds including the verification round.
    let mut certs = Vec::new();
    for cert in &unverified_certificates {
        let mut cert = cert.clone();
        if cert.round() != LEAF_ROUND {
            cert.set_signature_verification_state(SignatureVerificationState::Unverified(
                BlsSignature::default(),
            ));
        }
        certs.push(cert);
    }

    // expect error
    assert!(validator.process_fetched_certificates_in_parallel(certs).await.is_err());

    // fail to verify a batch of certificates with bad signatures for leaves and the verification
    // round, but good signatures at other rounds.
    let mut certs = Vec::new();
    for cert in &unverified_certificates {
        let round = cert.round();
        let mut cert = cert.clone();
        if round == VERIFICATION_ROUND || round == LEAF_ROUND {
            cert.set_signature_verification_state(SignatureVerificationState::Unverified(
                BlsSignature::default(),
            ));
        }
        certs.push(cert);
    }

    // expect error
    assert!(validator.process_fetched_certificates_in_parallel(certs).await.is_err());

    // Able to verify a batch of certificates with good signatures, but leaves in more rounds.
    let mut certs = Vec::new();
    for cert in &unverified_certificates {
        let r = cert.round();
        if r % 5 == 0 {
            continue;
        }
        certs.push(cert.clone());
    }

    // expect ok
    assert!(validator.process_fetched_certificates_in_parallel(certs).await.is_ok());

    Ok(())
}
