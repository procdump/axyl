//! state-sum — end-to-end audit of native USDR supply.
//!
//! Runs three independent measurements against a reth snapshot + a Blockscout
//! indexer, then asserts the reconciliation identity:
//!
//!     state_trie_sum  ==  (mints − burns)  +  genesis_alloc
//!
//! On agreement, computes and prints the hardfork correction:
//!
//!     correction = state_trie_sum − stored_TOTAL_SUPPLY_slot
//!
//! Usage:
//!
//!     state-sum [--datadir PATH] [--genesis PATH] [--explorer URL]
//!
//! See README.md for methodology, threat model, and expected numbers.

use std::collections::HashMap;
use std::path::PathBuf;
use std::time::Instant;

use alloy_primitives::{address, keccak256, Address, U256};
use eyre::{eyre, Result, WrapErr};
use reth_db::{open_db_read_only, tables, DatabaseEnv};
use reth_db_api::{
    cursor::{DbCursorRO, DbDupCursorRO},
    database::Database,
    transaction::DbTx,
};

const USDR_PRECOMPILE: Address = address!("0000000000000000000000000000000000000400");
const TOTAL_SUPPLY_PREFIX: [u8; 32] = *b"TOTAL_SUPPLY_V1__________STORAGE";

// keccak256("Transfer(address,address,uint256)")
const TRANSFER_TOPIC: &str = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
// keccak256("Approval(address,address,uint256)")
const APPROVAL_TOPIC: &str = "0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925";
// keccak256("Mint(address,uint256)")
const MINT_TOPIC: &str = "0x0f6798a560793a54c3bcfe86a93cde1e73087d944c0ea20544137d4121396885";
// keccak256("Burn(address,uint256)")
const BURN_TOPIC: &str = "0xcc16f5dbb4873280815c1ee09dbd06736cffcc184412cf7a71a0fdb75d397ca5";
const ZERO_TOPIC: &str = "0x0000000000000000000000000000000000000000000000000000000000000000";

struct Opts {
    datadir: PathBuf,
    genesis: Option<PathBuf>,
    explorer: String,
}

fn parse_args() -> Result<Opts> {
    let mut datadir = PathBuf::from("./db");
    let mut genesis: Option<PathBuf> = None;
    let mut explorer = std::env::var("RAYLS_EXPLORER")
        .unwrap_or_else(|_| "https://explorer.rayls.com".into());

    let argv: Vec<String> = std::env::args().skip(1).collect();
    let mut iter = argv.iter();
    while let Some(arg) = iter.next() {
        let need = |it: &mut std::slice::Iter<'_, String>| {
            it.next().cloned().ok_or_else(|| eyre!("{arg} requires a value"))
        };
        match arg.as_str() {
            "--datadir" => datadir = PathBuf::from(need(&mut iter)?),
            "--genesis" => genesis = Some(PathBuf::from(need(&mut iter)?)),
            "--explorer" => explorer = need(&mut iter)?,
            "-h" | "--help" => {
                print_help();
                std::process::exit(0);
            }
            // A bare path argument (no `--` prefix) is treated as the datadir
            // for convenience: `state-sum ~/snap/db --genesis ...`.
            other if !other.starts_with('-') => datadir = PathBuf::from(other),
            other => return Err(eyre!("unknown flag: {other} (try --help)")),
        }
    }
    Ok(Opts { datadir, genesis, explorer })
}

fn print_help() {
    println!(
        "state-sum — axyl USDR supply audit

USAGE:
  state-sum [DATADIR] [--genesis PATH] [--explorer URL]
  state-sum --datadir DATADIR --genesis PATH [--explorer URL]

OPTIONS:
  --datadir PATH         reth datadir containing mdbx.dat (default: ./db).
                         Also accepted as a bare positional argument.
  --genesis PATH         path to the chain's mainnet genesis YAML (e.g.
                         mgenesis.yaml). The script scans its `alloc:` block
                         and sums every nonzero `balance:` entry.
                         When given, the script asserts:
                            state_trie_sum == (mints − burns) + Σ alloc balances
                         and exits non-zero on mismatch.
                         When omitted, the script still prints all three
                         measurements but skips the assertion.
  --explorer URL         Blockscout base URL (default: $RAYLS_EXPLORER or
                         https://explorer.rayls.com)

EXIT CODES:
  0  audit passes (or no --genesis supplied; assertion skipped)
  2  reconciliation mismatch — INVESTIGATE
  3  stored slot > state-trie sum — INVESTIGATE"
    );
}

fn main() -> Result<()> {
    let opts = parse_args()?;

    println!("=== axyl USDR supply audit ===");
    println!("datadir             : {}", opts.datadir.display());
    println!("explorer            : {}", opts.explorer);
    println!("precompile          : {:#x}", USDR_PRECOMPILE);
    println!();

    // 1. State-trie measurement (the ground truth)
    let (state_trie_sum, stored_slot, n_accounts, n_nonzero, walk_ms) =
        walk_state_trie(&opts.datadir).wrap_err("state-trie walk")?;

    println!("── state trie ({} ms walk) ──", walk_ms);
    println!("  accounts (total / nonzero) : {n_accounts} / {n_nonzero}");
    println!(
        "  state_trie_sum             : {state_trie_sum} wei  ({} USDR)",
        wei_to_human(state_trie_sum)
    );
    println!(
        "  stored_total_supply        : {stored_slot} wei  ({} USDR)",
        wei_to_human(stored_slot)
    );
    println!();

    // 2. Event-replay measurement (from Blockscout)
    let events =
        walk_blockscout_logs(&opts.explorer).wrap_err("event replay against Blockscout")?;

    println!(
        "── event replay ({} logs, {} pages, {:.1}s) ──",
        events.total_logs, events.pages, events.wall_secs
    );
    println!("  topic[0] distribution:");
    let labels: HashMap<&str, &str> = [
        (TRANSFER_TOPIC, "Transfer"),
        (APPROVAL_TOPIC, "Approval"),
        (MINT_TOPIC, "Mint"),
        (BURN_TOPIC, "Burn"),
    ]
    .into_iter()
    .collect();
    let mut by_count: Vec<(&String, &u64)> = events.counts_by_topic.iter().collect();
    by_count.sort_by(|a, b| b.1.cmp(a.1));
    for (t, c) in by_count {
        let lbl = labels.get(t.as_str()).copied().unwrap_or("?");
        println!("    {c:>5}  {lbl:<10}  {t}");
    }
    println!(
        "  mint  events (Transfer from=0x0) : {} totalling {} wei  ({} USDR)",
        events.transfers_from_zero,
        events.mint_sum,
        wei_to_human(events.mint_sum)
    );
    println!(
        "  burn  events (Transfer to=0x0)   : {} totalling {} wei  ({} USDR)",
        events.transfers_to_zero,
        events.burn_sum,
        wei_to_human(events.burn_sum)
    );
    println!(
        "  other Transfer (user↔user)       : {} (no supply impact)",
        events.transfers_other
    );
    let net = events.mint_sum.saturating_sub(events.burn_sum);
    println!(
        "  net (mints − burns)              : {net} wei  ({} USDR)",
        wei_to_human(net)
    );
    println!();

    // 3. Reconciliation
    let mut exit: i32 = 0;
    if let Some(path) = &opts.genesis {
        let (total_addrs, entries, genesis_alloc) =
            parse_genesis_alloc(path).wrap_err_with(|| format!("parse {}", path.display()))?;

        println!("── genesis alloc ──");
        println!("  source              : {}", path.display());
        println!("  addresses (total / nonzero) : {} / {}", total_addrs, entries.len());
        println!(
            "  Σ alloc balances    : {} wei  ({} USDR)",
            genesis_alloc,
            wei_to_human(genesis_alloc)
        );
        for (addr, bal) in &entries {
            println!("    {}  {:>32} wei  ({} USDR)", addr, bal, wei_to_human(*bal));
        }
        println!();

        let derived = net + genesis_alloc;
        println!("── reconciliation ──");
        println!(
            "  events (mints − burns)     : {:>32} wei  ({} USDR)",
            net,
            wei_to_human(net)
        );
        println!(
            "  + genesis_alloc            : {:>32} wei  ({} USDR)",
            genesis_alloc,
            wei_to_human(genesis_alloc)
        );
        println!(
            "  = derived total supply     : {:>32} wei  ({} USDR)",
            derived,
            wei_to_human(derived)
        );
        println!(
            "  state_trie_sum             : {:>32} wei  ({} USDR)",
            state_trie_sum,
            wei_to_human(state_trie_sum)
        );
        if derived == state_trie_sum {
            println!("  delta                      : 0  ✓ PASS — three sources agree");
        } else {
            let (sign, diff) = if derived > state_trie_sum {
                ("+", derived - state_trie_sum)
            } else {
                ("-", state_trie_sum - derived)
            };
            println!(
                "  delta                      : {sign}{diff} wei  ({sign}{} USDR)  ✗ MISMATCH",
                wei_to_human(diff)
            );
            exit = 2;
        }
        println!();
    } else {
        println!("── reconciliation ──");
        println!("  (skipped: pass --genesis PATH to assert)");
        println!();
    }

    // 4. Correction
    println!("── hardfork correction ──");
    match state_trie_sum.checked_sub(stored_slot) {
        Some(c) => {
            println!(
                "  correction = state_trie_sum − stored_slot = {c} wei  ({} USDR)",
                wei_to_human(c)
            );
        }
        None => {
            let neg = stored_slot - state_trie_sum;
            println!(
                "  correction is NEGATIVE: stored_slot − state_trie_sum = {} wei",
                neg
            );
            println!("  (stored slot exceeds true sum — INVESTIGATE)");
            exit = 3;
        }
    }

    if exit != 0 {
        std::process::exit(exit);
    }
    Ok(())
}

// ── state trie ────────────────────────────────────────────────────────────
fn walk_state_trie(datadir: &std::path::Path) -> Result<(U256, U256, u64, u64, u128)> {
    let db: DatabaseEnv =
        open_db_read_only(datadir, Default::default()).wrap_err("open_db_read_only")?;
    let tx = db.tx().wrap_err("begin ro tx")?;

    let t0 = Instant::now();
    let mut cursor = tx
        .cursor_read::<tables::HashedAccounts>()
        .wrap_err("open HashedAccounts cursor")?;

    let mut accounts: u64 = 0;
    let mut nonzero: u64 = 0;
    let mut sum = U256::ZERO;
    let mut walker = cursor.walk(None).wrap_err("walk HashedAccounts")?;
    while let Some(entry) = walker.next() {
        let (_hashed_addr, account) = entry?;
        accounts += 1;
        if !account.balance.is_zero() {
            nonzero += 1;
        }
        sum = sum
            .checked_add(account.balance)
            .ok_or_else(|| eyre!("U256 overflow summing balances at #{accounts}"))?;
    }
    let walk_ms = t0.elapsed().as_millis();

    let hashed_precompile = keccak256(USDR_PRECOMPILE.as_slice());
    let slot_u256 = U256::from_be_bytes(keccak256(TOTAL_SUPPLY_PREFIX).0);
    let slot_be: [u8; 32] = slot_u256.to_be_bytes();
    let hashed_slot = keccak256(slot_be);

    let mut dup_cursor = tx
        .cursor_dup_read::<tables::HashedStorages>()
        .wrap_err("open HashedStorages cursor")?;
    let stored_slot = match dup_cursor
        .seek_by_key_subkey(hashed_precompile, hashed_slot)
        .wrap_err("seek HashedStorages")?
    {
        Some(entry) if entry.key == hashed_slot => entry.value,
        _ => U256::ZERO,
    };

    Ok((sum, stored_slot, accounts, nonzero, walk_ms))
}

// ── event replay (Blockscout) ─────────────────────────────────────────────
#[derive(Default)]
struct LogSummary {
    counts_by_topic: HashMap<String, u64>,
    transfers_from_zero: u64,
    transfers_to_zero: u64,
    transfers_other: u64,
    mint_sum: U256,
    burn_sum: U256,
    pages: u64,
    total_logs: u64,
    wall_secs: f64,
}

fn walk_blockscout_logs(explorer: &str) -> Result<LogSummary> {
    let base = format!(
        "{}/api/v2/addresses/{:#x}/logs",
        explorer.trim_end_matches('/'),
        USDR_PRECOMPILE
    );
    let mut url = base.clone();
    let mut s = LogSummary::default();
    let t0 = Instant::now();
    loop {
        let body: serde_json::Value = ureq::get(&url)
            // The public explorer 403s default user-agents via WAF; spoof curl.
            .set("User-Agent", "curl/8.7.1")
            .set("Accept", "application/json")
            .call()
            .wrap_err_with(|| format!("GET {url}"))?
            .into_json()
            .wrap_err("parse Blockscout JSON")?;

        if let Some(items) = body["items"].as_array() {
            for log in items {
                let topics = match log["topics"].as_array() {
                    Some(t) if !t.is_empty() => t,
                    _ => continue,
                };
                let t0_topic = topics[0].as_str().unwrap_or("").to_string();
                s.total_logs += 1;
                *s.counts_by_topic.entry(t0_topic.clone()).or_insert(0) += 1;
                if t0_topic == TRANSFER_TOPIC && topics.len() >= 3 {
                    let value = parse_u256_hex_data(log["data"].as_str().unwrap_or("0x"));
                    let from = topics[1].as_str().unwrap_or("");
                    let to = topics[2].as_str().unwrap_or("");
                    if from == ZERO_TOPIC {
                        s.transfers_from_zero += 1;
                        s.mint_sum += value;
                    } else if to == ZERO_TOPIC {
                        s.transfers_to_zero += 1;
                        s.burn_sum += value;
                    } else {
                        s.transfers_other += 1;
                    }
                }
            }
        }

        let next = &body["next_page_params"];
        if next.is_null() {
            break;
        }
        s.pages += 1;
        url = format!("{}?{}", base, json_obj_to_query(next));
    }
    s.pages += 1;
    s.wall_secs = t0.elapsed().as_secs_f64();
    Ok(s)
}

fn json_obj_to_query(v: &serde_json::Value) -> String {
    let obj = match v.as_object() {
        Some(o) => o,
        None => return String::new(),
    };
    let mut parts = Vec::new();
    for (k, val) in obj {
        let raw = match val {
            serde_json::Value::String(s) => s.clone(),
            serde_json::Value::Number(n) => n.to_string(),
            serde_json::Value::Null => String::new(),
            _ => val.to_string(),
        };
        parts.push(format!("{}={}", urlencode(k), urlencode(&raw)));
    }
    parts.join("&")
}

fn urlencode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn parse_u256(s: &str) -> Result<U256> {
    let s = s.trim();
    let parsed = if let Some(rest) = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
        U256::from_str_radix(rest, 16)
    } else {
        U256::from_str_radix(s, 10)
    };
    parsed.map_err(|e| eyre!("invalid uint256 `{s}`: {e}"))
}

fn parse_u256_hex_data(s: &str) -> U256 {
    if s == "0x" || s.is_empty() {
        return U256::ZERO;
    }
    let stripped = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")).unwrap_or(s);
    U256::from_str_radix(stripped, 16).unwrap_or(U256::ZERO)
}

fn wei_to_human(w: U256) -> String {
    let whole = w / U256::from(10u128.pow(18));
    let frac = w % U256::from(10u128.pow(18));
    format!("{whole}.{frac:0>18}")
}

/// Sum every nonzero `balance:` entry in the `alloc:` block of a reth genesis YAML.
/// Returns (total_address_count, [(addr, balance) for nonzero], sum_wei).
///
/// The YAML structure we expect is:
///   alloc:
///     "0xADDRESS":
///       nonce: "0x..."
///       balance: "0xHEX" | "DECIMAL"
///       code: "0x..."   (optional)
///       storage: ...    (optional)
fn parse_genesis_alloc(
    path: &std::path::Path,
) -> Result<(usize, Vec<(String, U256)>, U256)> {
    let text =
        std::fs::read_to_string(path).wrap_err_with(|| format!("read {}", path.display()))?;
    let addr_re = regex::Regex::new(r#"(?m)^\s*"(0x[0-9a-fA-F]{40})"\s*:\s*$"#)?;
    let bal_re = regex::Regex::new(r#"(?m)^\s*balance:\s*"([^"]+)"\s*$"#)?;
    let addr_matches: Vec<(usize, usize, String)> = addr_re
        .captures_iter(&text)
        .map(|c| {
            let m = c.get(0).unwrap();
            (m.start(), m.end(), c.get(1).unwrap().as_str().to_string())
        })
        .collect();
    let total_addrs = addr_matches.len();
    let mut entries: Vec<(String, U256)> = Vec::new();
    let mut total = U256::ZERO;
    for (i, (_, end, addr)) in addr_matches.iter().enumerate() {
        let next_start = addr_matches.get(i + 1).map(|p| p.0).unwrap_or(text.len());
        let section = &text[*end..next_start];
        if let Some(cap) = bal_re.captures(section) {
            let v = parse_u256(cap.get(1).unwrap().as_str())?;
            if !v.is_zero() {
                entries.push((addr.clone(), v));
                total += v;
            }
        }
    }
    entries.sort_by(|a, b| b.1.cmp(&a.1));
    Ok((total_addrs, entries, total))
}
