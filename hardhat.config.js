require('@nomicfoundation/hardhat-toolbox');
require('dotenv').config();

module.exports = {
  solidity: {
    version: '0.8.20',
    settings: { optimizer: { enabled: true, runs: 200 } }
  },
  networks: {
    pickle: {
      url: process.env.RPC_URL || 'https://rpc.picklechain.xyz',
      chainId: 78270,
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : []
    }
  }
};
