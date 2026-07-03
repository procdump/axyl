//! Unit tests for network types.rs

use super::NodeRecord;
use crate::common::create_multiaddr;
use rayls_infrastructure_config::KeyConfig;
use rayls_infrastructure_types::{BlsKeypair, BlsSigner};

#[test]
fn test_node_record() {
    let multiaddr = create_multiaddr(None);
    let bls_keypair = BlsKeypair::generate(&mut rand::rng());
    let pubkey = *bls_keypair.public();
    let key_config = KeyConfig::new_with_testing_key(bls_keypair);

    // build a valid node record
    let node_record =
        NodeRecord::build(key_config.primary_network_public_key(), multiaddr, |data| {
            key_config.request_signature_direct(data)
        });
    assert!(node_record.clone().verify(&pubkey).is_ok());

    // assert returned values match
    assert!(node_record.verify(&pubkey).is_ok());

    // assert incorrect pubkey fails
    let bad_keypair = BlsKeypair::generate(&mut rand::rng());
    assert!(node_record.verify(bad_keypair.public()).is_err());
}
