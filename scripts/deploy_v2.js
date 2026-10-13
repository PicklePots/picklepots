// Deploys PicklePotsV2 (implementation + ERC1967 proxy) to Pickle Chain testnet using plain ethers.
// Usage: DEPLOYER_KEY_FILE=/path/key.json node scripts/deploy_v2.js
// (Reads only the file you point it at; it never touches .env.)
const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');

const RPC = 'https://rpc.picklechain.xyz';
const OWNER = process.env.OWNER || '0x903d2AD79bBa6BB121FdF2102cA80469C6b735eb';
const FEE_RECIPIENT = process.env.PROTOCOL_FEE_RECIPIENT || '0x903d2AD79bBa6BB121FdF2102cA80469C6b735eb';
const FEE_ROUTER = process.env.FEE_ROUTER_ADDRESS || ethers.ZeroAddress;
const PKL = process.env.PKL_TOKEN || '0x8d1Ab7dD27a5Fd87452748012Dc7f319f51b877e';

const art = (n) => JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'artifacts', 'contracts', ...n), 'utf8'));

// Pickle Chain returns receipts with null blockHash at preconfirmation, which breaks ethers' wait().
async function receipt(p, hash) {
  for (let i = 0; i < 120; i++) {
    const r = await p.send('eth_getTransactionReceipt', [hash]).catch(() => null);
    if (r) return r;
    await new Promise((res) => setTimeout(res, 500));
  }
  throw new Error('receipt timeout ' + hash);
}

async function deploy(w, p, artifact, args = []) {
  const f = new ethers.ContractFactory(artifact.abi, artifact.bytecode, w);
  const tx = await f.getDeployTransaction(...args);
  const sent = await w.sendTransaction(tx);
  const r = await receipt(p, sent.hash);
  if (r.status !== '0x1') throw new Error('deploy reverted ' + sent.hash);
  return r.contractAddress;
}

(async () => {
  const k = JSON.parse(fs.readFileSync(process.env.DEPLOYER_KEY_FILE, 'utf8'));
  const p = new ethers.JsonRpcProvider(RPC, 78270, { staticNetwork: true });
  const w = new ethers.NonceManager(new ethers.Wallet(k.privateKey, p));
  console.log('Deployer:', await w.getAddress());

  const implArt = art(['PicklePotsV2.sol', 'PicklePotsV2.json']);
  const proxyArt = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'artifacts', '@openzeppelin', 'contracts', 'proxy', 'ERC1967', 'ERC1967Proxy.sol', 'ERC1967Proxy.json'), 'utf8'));
  const impl = await deploy(w, p, implArt);
  console.log('Implementation:', impl);
  const iface = new ethers.Interface(implArt.abi);
  const init = iface.encodeFunctionData('initialize', [OWNER, FEE_RECIPIENT, FEE_ROUTER, PKL]);
  const proxy = await deploy(w, p, proxyArt, [impl, init]);
  console.log('PROXY (use this address):', proxy);
  console.log('Owner:', OWNER, ' Fee recipient:', FEE_RECIPIENT, ' PKL:', PKL);
})().catch((e) => { console.error(e); process.exit(1); });
