const { expect } = require('chai');
const { ethers } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');
const E = ethers.parseEther;

async function deployV2ThenUpgrade() {
  const [owner, fee, a, b, c] = await ethers.getSigners();
  const pkl = await (await ethers.getContractFactory('MockPKL')).deploy();
  const impl2 = await (await ethers.getContractFactory('PicklePotsV2')).deploy();
  const init = impl2.interface.encodeFunctionData('initialize', [owner.address, fee.address, ethers.ZeroAddress, await pkl.getAddress()]);
  const proxy = await (await ethers.getContractFactory('ERC1967Proxy')).deploy(await impl2.getAddress(), init);
  const v2 = await ethers.getContractAt('PicklePotsV2', await proxy.getAddress());
  return { v2, proxy, owner, fee, a, b, c, pkl };
}

describe('PicklePotsV3 upgrade', () => {
  it('upgrades the live proxy in one tx, keeps state, and fixes the timers', async () => {
    const { v2, owner, a, b } = await deployV2ThenUpgrade();
    // state before the upgrade: a live round with a bid
    await v2.connect(a).dropBid(0, { value: E('0.0001') });
    const before = await v2.getRound(0);
    expect((await v2.tierConfigs(0)).extensionTime).to.equal(10);

    const impl3 = await (await ethers.getContractFactory('PicklePotsV3')).deploy();
    const data = impl3.interface.encodeFunctionData('initializeV3', []);
    await v2.connect(owner).upgradeToAndCall(await impl3.getAddress(), data);
    const v3 = await ethers.getContractAt('PicklePotsV3', await v2.getAddress());

    // state preserved
    const after = await v3.getRound(0);
    expect(after.potAmount).to.equal(before.potAmount);
    expect(after.leader).to.equal(before.leader);
    expect(await v3.numTiers()).to.equal(5);
    // timers fixed: [opening, reset, cap]
    const want = [[35, 25, 35], [40, 30, 40], [50, 35, 50], [60, 40, 60], [50, 35, 50]];
    for (let i = 0; i < 5; i++) {
      const c = await v3.tierConfigs(i);
      expect([Number(c.roundDuration), Number(c.extensionTime), Number(c.maxTimeCap)]).to.deep.equal(want[i]);
    }
    // a new bid now gives the next player 25s on the Cocktail jar, not 10s
    await v3.connect(b).dropBid(0, { value: E('0.0001') });
    const r = await v3.getRound(0);
    expect(Number(r.timeLeft)).to.be.within(24, 25);
    // and the other player can still counter 20s later
    await time.increase(20);
    await v3.connect(a).dropBid(0, { value: E('0.0001') });
    expect((await v3.getRound(0)).leader).to.equal(a.address);
  });

  it('initializeV3 cannot run twice, and only the owner can retune', async () => {
    const { v2, owner, a } = await deployV2ThenUpgrade();
    const impl3 = await (await ethers.getContractFactory('PicklePotsV3')).deploy();
    await v2.connect(owner).upgradeToAndCall(await impl3.getAddress(), impl3.interface.encodeFunctionData('initializeV3', []));
    const v3 = await ethers.getContractAt('PicklePotsV3', await v2.getAddress());
    await expect(v3.connect(owner).initializeV3()).to.be.reverted;
    await expect(v3.connect(a).setTierTiming(0, 30, 20, 30)).to.be.reverted;
    await v3.connect(owner).setTierTiming(0, 30, 20, 30);
    expect((await v3.tierConfigs(0)).extensionTime).to.equal(20);
    await expect(v3.connect(owner).setTierTiming(0, 30, 40, 30)).to.be.revertedWith('PicklePots: bad cap');
    await expect(v3.connect(owner).setTierTiming(9, 30, 20, 30)).to.be.revertedWith('PicklePots: Invalid tier');
    await expect(v3.connect(owner).setTierTiming(0, 30, 20, 100000)).to.be.revertedWith('PicklePots: timer too long');
  });

  it('non-owner cannot upgrade, and payouts still work after the upgrade', async () => {
    const { v2, owner, a, b, fee } = await deployV2ThenUpgrade();
    const impl3 = await (await ethers.getContractFactory('PicklePotsV3')).deploy();
    await expect(v2.connect(a).upgradeToAndCall(await impl3.getAddress(), '0x')).to.be.reverted;
    await v2.connect(owner).upgradeToAndCall(await impl3.getAddress(), impl3.interface.encodeFunctionData('initializeV3', []));
    const v3 = await ethers.getContractAt('PicklePotsV3', await v2.getAddress());
    await v3.connect(a).dropBid(1, { value: E('0.0005') });
    await v3.connect(b).dropBid(1, { value: E('0.0005') });
    await time.increase(60);
    const bBefore = await ethers.provider.getBalance(b.address);
    await v3.connect(a).finalizeRound(1);
    expect(await ethers.provider.getBalance(b.address) - bBefore).to.equal(E('0.001') * 9000n / 10000n);
  });
});
