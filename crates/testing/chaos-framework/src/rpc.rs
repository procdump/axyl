//! RPC helper functions for interacting with Axyl validator nodes.
//!
//! These are extracted from the e2e restart tests and generalized for reuse
//! across chaos scenarios.

use eyre::Report;
use jsonrpsee::{
    core::{client::ClientT, DeserializeOwned},
    http_client::HttpClientBuilder,
    rpc_params,
};
use rayls_infrastructure_types::{keccak256, Address, MIN_RAYLS_PROTOCOL_BASE_FEE};
use serde_json::Value;
use std::{collections::HashMap, fmt::Debug, sync::OnceLock, time::Duration};
use tokio::runtime::Runtime;
use tracing::{error, info};

/// Shared Tokio runtime for all RPC calls. Avoids creating/destroying a
/// thread pool on every call.
static RPC_RUNTIME: OnceLock<Runtime> = OnceLock::new();

fn rpc_runtime() -> &'static Runtime {
    RPC_RUNTIME.get_or_init(|| {
        // Multi-thread (not current_thread): call_rpc uses block_on and chaos
        // scenarios may call it concurrently. A shared current_thread runtime
        // panics on concurrent block_on, which forced tests to run with
        // --test-threads 1.
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_io()
            .enable_time()
            .build()
            .expect("failed to build RPC runtime")
    })
}

/// One unit of RLS (10^18) measured in wei.
pub const WEI_PER_RLS: u128 = 1_000_000_000_000_000_000;

/// Gas price for test transactions, pinned to the protocol base-fee floor.
///
/// Anything below `MIN_RAYLS_PROTOCOL_BASE_FEE` is parked in the basefee subpool
/// and never mined, so the recipient balance never updates and balance-based
/// assertions time out. Always send at (or above) this price.
pub const GAS_PRICE: u128 = MIN_RAYLS_PROTOCOL_BASE_FEE as u128;

/// Make an RPC call to a node, retrying up to `retries` times at 1-second intervals.
pub fn call_rpc<R, Params>(
    node: &str,
    command: &str,
    params: Params,
    retries: usize,
) -> eyre::Result<R>
where
    R: DeserializeOwned + Debug,
    Params: jsonrpsee::core::traits::ToRpcParams + Send + Clone + Debug,
{
    let resp = rpc_runtime().block_on(async move {
        // Build every client (initial AND retries) with the same request timeout,
        // so a hung node can't make a retry attempt block indefinitely.
        let build_client = || {
            HttpClientBuilder::default()
                .request_timeout(Duration::from_secs(5))
                .build(node)
                .expect("couldn't build rpc client")
        };
        let mut resp = build_client().request(command, params.clone()).await;
        let mut i = 0;
        while i < retries && resp.is_err() {
            tokio::time::sleep(Duration::from_secs(1)).await;
            resp = build_client().request(command, params.clone()).await;
            i += 1;
        }
        resp.inspect_err(|_| {
            error!(target: "chaos", ?command, ?node, ?params, "rpc call failed");
        })
    });

    Ok(resp?)
}

/// Get a block by number (or latest if `None`).
///
/// `eth_getBlockByNumber` returns JSON `null` when the requested block isn't
/// available yet — a transient state while a freshly-restarted node is still
/// catching up (seen under rapid kill/restart cycling). Deserializing `null`
/// straight into a map fails hard with "invalid type: null, expected a map",
/// and `call_rpc` only retries transport errors, not a successful `null` body.
/// So request an `Option` (where `null` parses cleanly to `None`) and retry on
/// `None`, surfacing a meaningful "node never produced a block" error instead of
/// a cryptic parse failure if it never recovers.
pub fn get_block(node: &str, block_number: Option<u64>) -> eyre::Result<HashMap<String, Value>> {
    let params = if let Some(block_number) = block_number {
        rpc_params!(format!("0x{block_number:x}"), true)
    } else {
        rpc_params!("latest", true)
    };

    for attempt in 0..15 {
        if attempt > 0 {
            std::thread::sleep(Duration::from_secs(1));
        }
        let block: Option<HashMap<String, Value>> =
            call_rpc(node, "eth_getBlockByNumber", params.clone(), 10)?;
        if let Some(block) = block {
            return Ok(block);
        }
    }

    Err(Report::msg(format!(
        "eth_getBlockByNumber({block_number:?}) on {node} returned null after retries \
         (node reachable but never served the block — likely failed to recover)"
    )))
}

/// Get the latest block number from a node.
pub fn get_block_number(node: &str) -> eyre::Result<u64> {
    let block = get_block(node, None)?;
    // Error on a missing/malformed `number` rather than silently returning 0,
    // which would mask a bad RPC response as "block 0".
    let number = block
        .get("number")
        .and_then(|v| v.as_str())
        .ok_or_else(|| Report::msg("eth_getBlockByNumber response missing `number`"))?;
    Ok(u64::from_str_radix(number.strip_prefix("0x").unwrap_or(number), 16)?)
}

/// Get the next (pending) nonce for an address via `eth_getTransactionCount`.
///
/// Use this instead of assuming a starting nonce of 0: the dev-funded ceremony
/// account (`test-source`) begins at a genesis nonce of 5+N, so hardcoded nonces
/// are rejected as "nonce too low".
pub fn get_transaction_count(node: &str, address: &str) -> eyre::Result<u128> {
    let res_str: String =
        call_rpc(node, "eth_getTransactionCount", rpc_params!(address, "pending"), 5)?;
    Ok(u128::from_str_radix(res_str.strip_prefix("0x").unwrap_or(&res_str), 16)?)
}

/// Get the balance of an address (in wei) from a node.
pub fn get_balance(node: &str, address: &str, retries: usize) -> eyre::Result<u128> {
    let res_str: String =
        call_rpc(node, "eth_getBalance", rpc_params!(address, "latest"), retries)?;
    let rls = u128::from_str_radix(res_str.strip_prefix("0x").unwrap_or(&res_str), 16)?;
    Ok(rls)
}

/// Retry up to 45 times (at ~1.2s intervals) to get a balance above `above`.
pub fn get_balance_above_with_retry(node: &str, address: &str, above: u128) -> eyre::Result<u128> {
    let mut bal = get_balance(node, address, 5)?;
    let mut i = 0;
    while i < 45 && bal <= above {
        std::thread::sleep(Duration::from_millis(1200));
        i += 1;
        bal = get_balance(node, address, 5)?;
    }
    if i == 45 && bal <= above {
        error!(target: "chaos", "get_balance_above_with_retry timed out");
        Err(Report::msg(format!("Failed to get a balance {bal} for {address} above {above}")))
    } else {
        Ok(bal)
    }
}

/// Retry up to 45 times to get a positive balance.
pub fn get_positive_balance_with_retry(node: &str, address: &str) -> eyre::Result<u128> {
    get_balance_above_with_retry(node, address, 0)
}

/// Derive a deterministic address from a word (used for test accounts).
pub fn address_from_word(key_word: &str) -> Address {
    let seed = keccak256(key_word.as_bytes());
    let mut rand =
        <secp256k1::rand::rngs::StdRng as secp256k1::rand::SeedableRng>::from_seed(seed.0);
    let secp = secp256k1::Secp256k1::new();
    let (_, public_key) = secp.generate_keypair(&mut rand);
    let hash = keccak256(&public_key.serialize_uncompressed()[1..]);
    Address::from_slice(&hash[12..])
}

/// Derive (account, public_key_hex, secret_key_hex) from a word.
pub fn account_from_word(key_word: &str) -> (String, String, String) {
    let seed = keccak256(key_word.as_bytes());
    let mut rand =
        <secp256k1::rand::rngs::StdRng as secp256k1::rand::SeedableRng>::from_seed(seed.0);
    let secp = secp256k1::Secp256k1::new();
    let (secret_key, public_key) = secp.generate_keypair(&mut rand);
    let keypair = secp256k1::Keypair::from_secret_key(&secp, &secret_key);
    let hash = keccak256(&public_key.serialize_uncompressed()[1..]);
    let address = Address::from_slice(&hash[12..]);
    let pubkey = keypair.public_key().serialize();
    let secret = keypair.secret_bytes();
    (address.to_string(), const_hex::encode(pubkey), const_hex::encode(secret))
}

/// Derive the sender address from a (resolved) hex-encoded secp256k1 secret key.
///
/// Takes the same already-resolved key string that `send_rls` consumes (i.e. the
/// output of [`get_key`]), so the address matches the account the tx is signed by.
pub fn address_from_key(key: &str) -> eyre::Result<Address> {
    use secp256k1::SecretKey;
    let key_bytes: [u8; 32] = const_hex::decode(key)?
        .try_into()
        .map_err(|_| Report::msg("Invalid secret key length, expected 32 bytes"))?;
    let secret_key = SecretKey::from_byte_array(key_bytes)?;
    let secp = secp256k1::Secp256k1::new();
    let public_key = secret_key.public_key(&secp);
    let hash = keccak256(&public_key.serialize_uncompressed()[1..]);
    Ok(Address::from_slice(&hash[12..]))
}

/// Get the hex-encoded secret key string, resolving word-based keys.
pub fn get_key(key: &str) -> String {
    if key.starts_with("0x") {
        key.to_string()
    } else {
        let (_, _, key) = account_from_word(key);
        key
    }
}

/// Create, sign, and submit a legacy transaction to transfer RLS.
pub fn send_rls(
    node: &str,
    key: &str,
    to_account: Address,
    amount: u128,
    gas_price: u128,
    gas: u128,
    nonce: u128,
) -> eyre::Result<()> {
    use ethereum_tx_sign::{LegacyTransaction, Transaction};
    use secp256k1::SecretKey;

    let mut to_addr = [0_u8; 20];
    to_addr.copy_from_slice(to_account.as_slice());
    let new_transaction = LegacyTransaction {
        chain: crate::CHAIN_ID,
        nonce,
        to: Some(to_addr),
        value: amount,
        gas_price,
        gas,
        data: vec![],
    };
    let key_bytes: [u8; 32] = const_hex::decode(key)?
        .try_into()
        .map_err(|_| Report::msg("Invalid secret key length, expected 32 bytes"))?;
    let secret_key = SecretKey::from_byte_array(key_bytes)?;
    let ecdsa = new_transaction
        .ecdsa(&secret_key.secret_bytes())
        .map_err(|_| Report::msg("Failed to get ecdsa"))?;
    let transaction_bytes = new_transaction.sign(&ecdsa);
    let res_str: String = call_rpc(
        node,
        "eth_sendRawTransaction",
        rpc_params!(const_hex::encode(transaction_bytes)),
        1,
    )?;
    info!(target: "chaos", "Submitted RLS transfer to {to_account} for {amount}: {res_str}");
    Ok(())
}

/// Send RLS and confirm the balance updates on a test node.
pub fn send_and_confirm(
    send_node: &str,
    confirm_node: &str,
    key: &str,
    to_account: Address,
) -> eyre::Result<()> {
    // Fetch the sender's current (pending) nonce rather than assuming 0 — the
    // dev-funded `test-source` account starts at a genesis nonce of 5+N. Because
    // this fn waits for the transfer to confirm before returning, sequential calls
    // observe the incremented nonce correctly.
    let sender = address_from_key(key)?;
    let nonce = get_transaction_count(send_node, &sender.to_string())?;
    let current = get_balance(confirm_node, &to_account.to_string(), 1)?;
    let amount = 10 * WEI_PER_RLS;
    let expected = current + amount;
    send_rls(send_node, key, to_account, amount, GAS_PRICE, 21000, nonce)?;

    std::thread::sleep(Duration::from_millis(1000));

    let bal = get_balance_above_with_retry(confirm_node, &to_account.to_string(), expected - 1)?;
    if expected != bal {
        return Err(Report::msg(format!("Expected a balance of {expected} got {bal}!")));
    }
    Ok(())
}
