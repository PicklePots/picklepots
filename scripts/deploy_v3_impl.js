// Deploys ONLY the PicklePotsV3 implementation (no proxy). The live proxy is upgraded afterwards by the OWNER wallet.
// Usage: DEPLOYER_KEY_FILE=/path/key.json node scripts/deploy_v3_impl.js   (never reads .env)
const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');
const art = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'artifacts', 'contracts', 'PicklePotsV3.sol', 'PicklePotsV3.json'), 'utf8'));
(async () => {
  const k = JSON.parse(fs.readFileSync(process.env.DEPLOYER_KEY_FILE, 'utf8'));
  const p = new ethers.JsonRpcProvider('https://rpc.picklechain.xyz', 78270, { staticNetwork: true });
  const w = new ethers.Wallet(k.privateKey, p);
  const tx = await new ethers.ContractFactory(art.abi, art.bytecode, w).getDeployTransaction();
  const sent = await w.sendTransaction(tx);
  let r = null;
  for (let i = 0; i < 120 && !r; i++) { r = await p.send('eth_getTransactionReceipt', [sent.hash]).catch(() => null); if (!r) await new Promise((s) => setTimeout(s, 500)); }
  if (!r || r.status !== '0x1') throw new Error('deploy failed ' + sent.hash);
  console.log('V3 implementation:', r.contractAddress);
  const i = new ethers.Interface(art.abi);
  console.log('upgradeToAndCall data:', new ethers.Interface(['function upgradeToAndCall(address,bytes)']).encodeFunctionData('upgradeToAndCall', [r.contractAddress, i.encodeFunctionData('initializeV3', [])]));
})().catch((e) => { console.error(e.message); process.exit(1); });
