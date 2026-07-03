use crate::{codec::RLMessage, types::NetworkEvent, ConsensusNetwork};
use rayls_infrastructure_types::{Database, RaylsSender};

impl<Req, Res, DB, Events> std::fmt::Debug for ConsensusNetwork<Req, Res, DB, Events>
where
    Req: RLMessage,
    Res: RLMessage,
    DB: Database,
    Events: RaylsSender<NetworkEvent<Req, Res>>,
{
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ConsensusNetwork")
            .field("authorized_publishers", &self.authorized_publishers)
            .field("pending_px_disconnects", &self.pending_px_disconnects)
            .field("outbound_requests", &self.outbound_requests.len())
            .field("inbound_requests", &self.inbound_requests.len())
            .field("config", &self.config)
            .field("connected_peers", &self.connected_peers)
            .field("swarm", &"<swarm>") // Skip detailed debug for swarm
            .finish()
    }
}
