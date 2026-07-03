//! Define the block header for the rayls "Consensus Chain"
//!
//! This is a very simple (data only) chain that records consesus output.
//! It can be used to validate the execution chain, catch up with consesus,
//! introduce a new validator to participate in consensus (either as a voter
//! or observer) or any task that requires realtime or historic consesus data
//! if not directly participating in consesus.

use super::{CommittedSubDag, ConsensusOutput};
use crate::{
    bcs_layout::{BcsCursor, BcsLayout, BcsLayoutError},
    crypto,
    error::CertificateResult,
    BlockHash, BlsPublicKey, Certificate, Committee, Hash, B256,
};
use serde::{Deserialize, Serialize};
use std::sync::Arc;

/// Header for the consensus chain.
///
/// The consensus chain records consensus output used to extend the execution chain.
/// All hashes are Keccak 256.
#[derive(PartialEq, Serialize, Deserialize, Clone, Debug)]
pub struct ConsensusHeader {
    /// The hash of the previous ConsesusHeader in the chain.
    pub parent_hash: B256,

    /// This is the committed sub dag used to extend the execution chain.
    pub sub_dag: CommittedSubDag,

    /// A scalar value equal to the number of ancestor blocks. The genesis block has a number of
    /// zero.
    pub number: u64,

    /// Temp extra data field - currently unused.
    /// This is included for now for testnet purposes only.
    pub extra: B256,
}

impl ConsensusHeader {
    /// Return the digest for this ConsensusHeader.
    pub fn digest(&self) -> BlockHash {
        Self::digest_from_parts(self.parent_hash, &self.sub_dag, self.number)
    }

    /// Produce the digest that result from a ConsensusHeader with this data.
    /// This allows digesting in some cases with out cloning a CommittedSubDag.
    pub fn digest_from_parts(
        parent_hash: B256,
        sub_dag: &CommittedSubDag,
        number: u64,
    ) -> BlockHash {
        let mut hasher = crypto::DefaultHashFunction::new();
        hasher.update(parent_hash.as_slice());
        hasher.update(sub_dag.digest().as_ref());
        hasher.update(number.to_le_bytes().as_ref());
        BlockHash::from_slice(hasher.finalize().as_bytes())
    }

    /// Verify that all certificates are valid and signed by a quorum of committee.
    pub fn verify_header(self, committee: &Committee) -> CertificateResult<Self> {
        self.verify_header_with_keys(&committee.bls_keys())
    }

    /// Verify all certificates using raw BLS public keys.
    pub fn verify_header_with_keys(self, keys: &[BlsPublicKey]) -> CertificateResult<Self> {
        let Self { parent_hash, sub_dag, number, extra } = self;
        let sub_dag = sub_dag.verify_certificates_with_keys(keys)?;
        Ok(Self { parent_hash, sub_dag, number, extra })
    }
}

impl Default for ConsensusHeader {
    fn default() -> Self {
        let sub_dag = CommittedSubDag::new(
            vec![],
            Certificate::default(),
            0,
            crate::ReputationScores::default(),
            None,
        );
        Self { parent_hash: B256::default(), sub_dag, number: 0, extra: B256::default() }
    }
}

impl From<ConsensusOutput> for ConsensusHeader {
    fn from(value: ConsensusOutput) -> Self {
        Self {
            parent_hash: value.parent_hash,
            sub_dag: Arc::unwrap_or_clone(value.sub_dag),
            number: value.number,
            extra: value.extra,
        }
    }
}

impl From<&[u8]> for ConsensusHeader {
    fn from(value: &[u8]) -> Self {
        crate::decode(value)
    }
}

/// BCS layout: `parent_hash, sub_dag, number, extra`. Keep in lockstep with the
/// struct.
impl BcsLayout for ConsensusHeader {
    fn skip(c: &mut BcsCursor<'_>) -> Result<(), BcsLayoutError> {
        c.skip::<B256>()?.skip::<CommittedSubDag>()?.skip::<u64>()?.skip::<B256>()?;
        Ok(())
    }
}

impl From<&ConsensusHeader> for Vec<u8> {
    fn from(value: &ConsensusHeader) -> Self {
        crate::encode(value)
    }
}

#[cfg(test)]
mod bcs_layout_tests {
    use super::*;
    use crate::{
        bcs_layout::{BcsCursor, BcsLayout},
        AuthorityIdentifier, BlockHash, BlsSignature, Certificate, CertificateDigest,
        HeaderBuilder, ReputationScores, SignatureVerificationState, WorkerId,
    };
    use indexmap::IndexMap;
    use std::collections::BTreeSet;

    fn skip_consumes(h: &ConsensusHeader) {
        let bytes = crate::encode(h);
        let mut c = BcsCursor::new(&bytes);
        ConsensusHeader::skip(&mut c).unwrap();
        assert!(c.is_empty(), "{} bytes left after ConsensusHeader::skip", c.len());
    }

    fn make_cert(
        author: u8,
        round: u32,
        epoch: u32,
        payload_len: usize,
        parents: usize,
    ) -> Certificate {
        let mut payload = IndexMap::<BlockHash, WorkerId>::new();
        for i in 0..payload_len {
            payload.insert(BlockHash::repeat_byte(i as u8), (i % 4) as u16);
        }
        let mut parents_set = BTreeSet::<CertificateDigest>::new();
        for i in 0..parents {
            parents_set.insert(CertificateDigest::new([i as u8; 32]));
        }
        let header = HeaderBuilder::default()
            .author(AuthorityIdentifier::dummy_for_test(author))
            .round(round)
            .epoch(epoch)
            .created_at(123)
            .payload(payload)
            .parents(parents_set)
            .build();
        let mut cert = Certificate::default();
        cert.update_header_for_test(header);
        cert
    }

    #[test]
    fn skip_empty_sub_dag() {
        let h = ConsensusHeader::default();
        skip_consumes(&h);
    }

    #[test]
    fn skip_populated_sub_dag() {
        let leader = make_cert(0xAA, 4, 7, 3, 2);
        let certs = vec![
            make_cert(0x11, 3, 7, 1, 0),
            make_cert(0x22, 3, 7, 2, 1),
            make_cert(0x33, 3, 7, 0, 1),
        ];
        let sub_dag = CommittedSubDag::new(certs, leader, 0, ReputationScores::default(), None);
        let h = ConsensusHeader {
            parent_hash: BlockHash::repeat_byte(0x99),
            sub_dag,
            number: 1234,
            extra: BlockHash::repeat_byte(0xEE),
        };
        skip_consumes(&h);
    }

    #[test]
    fn skip_handles_all_sig_state_variants() {
        let sigs = [
            SignatureVerificationState::Unsigned(BlsSignature::default()),
            SignatureVerificationState::Unverified(BlsSignature::default()),
            SignatureVerificationState::VerifiedDirectly(BlsSignature::default()),
            SignatureVerificationState::Genesis,
        ];
        for s in sigs {
            let mut cert = make_cert(0xAB, 2, 1, 1, 0);
            cert.set_signature_verification_state(s);
            let sub_dag = CommittedSubDag::new(
                vec![cert.clone()],
                cert,
                0,
                ReputationScores::default(),
                None,
            );
            let h = ConsensusHeader {
                parent_hash: BlockHash::ZERO,
                sub_dag,
                number: 0,
                extra: BlockHash::ZERO,
            };
            skip_consumes(&h);
        }
    }
}
