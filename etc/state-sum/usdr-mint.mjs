// Mint USDR via NativeTokenController to demonstrate that totalSupply moves.
//
// Run from etc/tps so node finds ethers in the local node_modules:
//   cd ~/repos/axyl/etc/tps && node /tmp/usdr-mint.mjs [USDR_AMOUNT]
//
// Default amount: 1000 USDR. The dev account 0xf39...266 mints to itself.
import { ethers } from 'ethers';

const RPC          = 'http://localhost:7545';
const DEV_PK       = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';
const NTC          = '0x07e17e17e17e17e17e17e17e17e17e17e17e17e6'; // NativeTokenController
const PRECOMPILE   = '0x0000000000000000000000000000000000000400'; // USDR ERC-20 precompile

const NTC_ABI = [
  'function isMinter(address) view returns (bool)',
  'function addMinter(address)',
  'function mint(address, uint256)',
];
const ERC20_ABI = ['function totalSupply() view returns (uint256)'];

async function main() {
  const amountUsdr = process.argv[2] || '1000';
  const amountWei  = ethers.parseEther(amountUsdr);

  const provider   = new ethers.JsonRpcProvider(RPC);
  const wallet     = new ethers.Wallet(DEV_PK, provider);
  const ntc        = new ethers.Contract(NTC,        NTC_ABI,   wallet);
  const precompile = new ethers.Contract(PRECOMPILE, ERC20_ABI, provider);

  const before = await precompile.totalSupply();
  console.log(`BEFORE  totalSupply = ${before} wei (${ethers.formatEther(before)} USDR)`);

  // 1) ensure the wallet has MINTER_ROLE
  // isMinter is occasionally flaky on ethers (returns empty data — likely
  // an RPC-side transient). Wrap in try/catch and trust the contract to
  // enforce the role on the actual mint tx.
  let has = false;
  try {
    has = await ntc.isMinter(wallet.address);
  } catch (e) {
    console.log(`isMinter returned empty/garbage (${e.shortMessage || e.code}), assuming role not granted yet`);
  }
  if (!has) {
    console.log(`attempting to grant MINTER_ROLE to ${wallet.address}...`);
    try {
      const t = await ntc.addMinter(wallet.address, { gasLimit: 200_000 });
      console.log(`  addMinter tx ${t.hash}`);
      await t.wait();
    } catch (e) {
      console.log(`  addMinter reverted (probably already granted): ${e.shortMessage || e.code}`);
    }
  } else {
    console.log(`MINTER_ROLE already granted to ${wallet.address}`);
  }

  // 2) mint — explicit gasLimit. Default estimator can come back low because
  //    the precompile's behaviour under eth_estimateGas can leave the actual
  //    tx with too little gas to forward (63/64 rule) to the precompile's
  //    own gas cost. Burn hits this reliably; mint less often but same
  //    failure mode if it ever lands.
  console.log(`minting ${amountUsdr} USDR to ${wallet.address} ...`);
  const t = await ntc.mint(wallet.address, amountWei, { gasLimit: 250_000 });
  console.log(`  mint tx ${t.hash}`);
  const rcpt = await t.wait();
  console.log(`  status: ${rcpt.status === 1 ? 'success' : 'FAILED'}  gasUsed: ${rcpt.gasUsed}`);

  const after = await precompile.totalSupply();
  const delta = after - before;
  console.log(`AFTER   totalSupply = ${after} wei (${ethers.formatEther(after)} USDR)`);
  console.log(`delta   ${delta} wei (${ethers.formatEther(delta)} USDR)`);
}

main().catch(e => { console.error(e); process.exit(1); });
