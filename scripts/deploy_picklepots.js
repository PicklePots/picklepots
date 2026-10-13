const hre = require('hardhat');

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log('==================================================');
  console.log('🥒 DEPLOYING 4-TIER PICKLEPOTS TO PICKLE CHAIN');
  console.log('==================================================');
  console.log('Deployer Address:', deployer.address);
  console.log('Network:', hre.network.name, '(Chain ID: 78270 / 0x131be)');
  console.log('RPC Endpoint:', hre.network.config.url || 'https://rpc.picklechain.xyz');

  const FEE_RECIPIENT = process.env.PROTOCOL_FEE_RECIPIENT || '0x903d2AD79bBa6BB121FdF2102cA80469C6b735eb';
  console.log('Protocol Fee Recipient:', FEE_RECIPIENT);

  const FEE_ROUTER_ADDRESS = process.env.FEE_ROUTER_ADDRESS || hre.ethers.ZeroAddress;

  const PicklePots = await hre.ethers.getContractFactory('PicklePots');
  const pots = await PicklePots.deploy(FEE_RECIPIENT, FEE_ROUTER_ADDRESS);

  await pots.waitForDeployment();
  const potsAddress = await pots.getAddress();

  console.log('--------------------------------------------------');
  console.log('✅ PicklePots deployed successfully to:', potsAddress);
  console.log('Genesis rounds live across all 4 tiers!');
  console.log('Tier 0: Cocktail Jar (0.0001 ETH)');
  console.log('Tier 1: Baby Gherkin (0.0005 ETH)');
  console.log('Tier 2: Classic Dill (0.002 ETH)');
  console.log('Tier 3: Spicy Brine (0.02 ETH)');
  console.log('==================================================');
}

main().catch((error) => {
  console.error('Deployment failed:', error);
  process.exitCode = 1;
});
