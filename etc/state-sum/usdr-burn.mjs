// Burn USDR via NativeTokenController.burn (which calls the precompile's burnFrom).
//
// Run from etc/tps so node finds ethers in the local node_modules:
//   cd ~/repos/axyl/etc/tps && node usdr-burn.mjs [USDR_AMOUNT]
//
// Default amount: 500 USDR. The dev account 0xf39...266 burns from itself,
// approving NTC as the spender first (and only if not already approved with
// enough allowance).
import { ethers } from 'ethers';

const RPC        = 'http://localhost:7545';
const DEV_PK     = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';
const NTC        = '0x07e17e17e17e17e17e17e17e17e17e17e17e17e6';
const PRECOMPILE = '0x0000000000000000000000000000000000000400';

const NTC_ABI = [
  'function isMinter(address) view returns (bool)',
  'function addMinter(address)',
  'function burn(address, uint256)',
];

const PRECOMPILE_ABI = [
  'function totalSupply() view returns (uint256)',
  'function balanceOf(address) view returns (uint256)',
  'function allowance(address owner, address spender) view returns (uint256)',
  'function approve(address spender, uint256 amount) returns (bool)',
];

async function main() {
  const amountUsdr = process.argv[2] || '500';
  const amountWei  = ethers.parseEther(amountUsdr);

  const provider   = new ethers.JsonRpcProvider(RPC);
  const wallet     = new ethers.Wallet(DEV_PK, provider);
  const ntc        = new ethers.Contract(NTC, NTC_ABI, wallet);
  const precompile = new ethers.Contract(PRECOMPILE, PRECOMPILE_ABI, wallet);

  const supplyBefore = await precompile.totalSupply();
  const balBefore    = await precompile.balanceOf(wallet.address);
  console.log(`BEFORE  totalSupply = ${supplyBefore} wei (${ethers.formatEther(supplyBefore)} USDR)`);
  console.log(`BEFORE  balanceOf(dev) = ${balBefore} wei (${ethers.formatEther(balBefore)} USDR)`);

  // 1) ensure MINTER_ROLE (NTC.burn is also onlyRole(MINTER_ROLE))
  // isMinter is occasionally flaky on ethers (returns empty data — likely
  // an RPC-side transient). Wrap in try/catch and trust the contract to
  // enforce the role on the actual burn tx.
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

  // 2) approve NTC to spend `amountWei` on behalf of dev (precompile.burnFrom
  //    consumes the allowance even for whitelisted callers).
  const cur = await precompile.allowance(wallet.address, NTC);
  if (cur < amountWei) {
    console.log(`approving NTC for ${amountUsdr} USDR (current allowance: ${ethers.formatEther(cur)} USDR)...`);
    const t = await precompile.approve(NTC, amountWei);
    console.log(`  approve tx ${t.hash}`);
    await t.wait();
  } else {
    console.log(`allowance already sufficient (${ethers.formatEther(cur)} USDR ≥ ${amountUsdr} USDR)`);
  }

  // 3) burn — set an explicit gasLimit. Default estimator can come back low
  //    because the precompile's behaviour under eth_estimateGas can leave
  //    the actual tx with too little gas to forward (63/64 rule) to the
  //    precompile's 10k-gas burnFrom path.
  console.log(`burning ${amountUsdr} USDR from ${wallet.address} ...`);
  const t = await ntc.burn(wallet.address, amountWei, { gasLimit: 250_000 });
  console.log(`  burn tx ${t.hash}`);
  const rcpt = await t.wait();
  console.log(`  status: ${rcpt.status === 1 ? 'success' : 'FAILED'}  gasUsed: ${rcpt.gasUsed}`);

  const supplyAfter = await precompile.totalSupply();
  const balAfter    = await precompile.balanceOf(wallet.address);
  console.log(`AFTER   totalSupply = ${supplyAfter} wei (${ethers.formatEther(supplyAfter)} USDR)`);
  console.log(`AFTER   balanceOf(dev) = ${balAfter} wei (${ethers.formatEther(balAfter)} USDR)`);
  console.log(`supply delta = ${supplyAfter - supplyBefore} wei (${ethers.formatEther(supplyAfter - supplyBefore)} USDR)`);
  console.log(`balance delta = ${balAfter - balBefore} wei (${ethers.formatEther(balAfter - balBefore)} USDR)`);
}

main().catch(e => { console.error(e); process.exit(1); });
