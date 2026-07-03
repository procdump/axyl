use crate::{
    kad::KadStore,
    peers::{self, PeerManager},
};
use libp2p::{
    gossipsub::{self},
    kad::{self},
    request_response::{self, Codec},
    swarm::NetworkBehaviour,
};
use rayls_infrastructure_config::PeerConfig;
use rayls_infrastructure_types::Database;

/// Custom network libp2p behaviour type for Rayls Network.
///
/// The behavior includes gossipsub and request-response.
#[derive(NetworkBehaviour)]
pub(crate) struct RLBehavior<C, DB>
where
    C: Codec + Send + Clone + 'static,
{
    /// The gossipsub network behavior.
    pub(crate) gossipsub: gossipsub::Behaviour,
    /// The request-response network behavior.
    pub(crate) req_res: request_response::Behaviour<C>,
    /// The peer manager.
    pub(crate) peer_manager: peers::PeerManager,
    /// Used for peer discovery.
    pub(crate) kademlia: kad::Behaviour<KadStore<DB>>,
}

impl<C, DB> RLBehavior<C, DB>
where
    C: Codec + Send + Clone + 'static,
    DB: Database,
{
    /// Create a new instance of Self.
    pub(crate) fn new(
        gossipsub: gossipsub::Behaviour,
        req_res: request_response::Behaviour<C>,
        kademlia: kad::Behaviour<KadStore<DB>>,
        peer_config: &PeerConfig,
    ) -> Self {
        let peer_manager = PeerManager::new(peer_config);
        Self { gossipsub, req_res, peer_manager, kademlia }
    }
}
