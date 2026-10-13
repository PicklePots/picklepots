const { expect } = require('chai');
const { ethers } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

const E = ethers.parseEther;

async function deploy() {
  const [owner, fee, a, b, c, d] = await ethers.getSigners();
  const pkl = await (await ethers.getContractFactory('MockPKL')).deploy();
  const impl = await (await ethers.getContractFactory('PicklePotsV2')).deploy();
  const init = impl.interface.encodeFunctionData('initialize', [owner.address, fee.address, ethers.ZeroAddress, await pkl.getAddress()]);
  const proxy = await (await ethers.getContractFactory('ERC1967Proxy')).deploy(await impl.getAddress(), init);
  const pots = await ethers.getContractAt('PicklePotsV2', await proxy.getAddress());
  for (const s of [a, b, c, d]) await pkl.mint(s.address, E('1000'));
  return { pots, pkl, impl, owner, fee, a, b, c, d };
}

describe('PicklePotsV2', () => {
  it('sets up 5 jars with PKL as tier 4 and keeps the v1 call selectors', async () => {
    const { pots, pkl } = await deploy();
    expect(await pots.numTiers()).to.equal(5);
    expect((await pots.tierConfigs(4)).token).to.equal(await pkl.getAddress());
    expect(pots.interface.getFunction('dropBid').selector).to.equal('0x5187338c');
    expect(pots.interface.getFunction('getRound').selector).to.equal('0xb4e5a830');
    const r = await pots.getRound(0);
    expect(r.tierName).to.equal('Cocktail Jar');
    expect(r.minBid).to.equal(E('0.0001'));
  });

  it('two players: 90% winner, 5% fee, 5% seed to next round', async () => {
    const { pots, fee, a, b } = await deploy();
    await pots.connect(a).dropBid(0, { value: E('0.0001') });
    await pots.connect(b).dropBid(0, { value: E('0.0003') });
    await time.increase(60);
    const feeBefore = await ethers.provider.getBalance(fee.address);
    const bBefore = await ethers.provider.getBalance(b.address);
    await pots.connect(a).finalizeRound(0);
    const pot = E('0.0004');
    expect(await ethers.provider.getBalance(b.address) - bBefore).to.equal(pot * 9000n / 10000n);
    expect(await ethers.provider.getBalance(fee.address) - feeBefore).to.equal(pot * 500n / 10000n);
    const r = await pots.getRound(0);
    expect(r.roundId).to.equal(2);
    expect(r.potAmount).to.equal(pot * 500n / 10000n);
    const last = await pots.getLastResult(0);
    expect(last.winner).to.equal(b.address);
    expect(last.refunded).to.equal(false);
  });

  it('solo player (even bidding many times) is refunded in full, no fee, seed rolls over', async () => {
    const { pots, fee, a, b } = await deploy();
    // build a seed first: contested round
    await pots.connect(a).dropBid(1, { value: E('0.0005') });
    await pots.connect(b).dropBid(1, { value: E('0.0005') });
    await time.increase(90);
    await pots.finalizeRound(1);
    const seed = (await pots.getRound(1)).potAmount;
    expect(seed).to.equal(E('0.001') * 500n / 10000n);

    // solo round with the same wallet bidding 3 times
    await pots.connect(a).dropBid(1, { value: E('0.0005') });
    await pots.connect(a).dropBid(1, { value: E('0.0007') });
    await pots.connect(a).dropBid(1, { value: E('0.0005') });
    expect((await pots.getRoundExtra(1)).uniqueBidders).to.equal(1);
    await time.increase(90);
    const feeBefore = await ethers.provider.getBalance(fee.address);
    const potBefore = await ethers.provider.getBalance(await pots.getAddress());
    const aBefore = await ethers.provider.getBalance(a.address);
    const tx = await pots.connect(b).finalizeRound(1); // someone else pays gas
    await tx.wait();
    expect(await ethers.provider.getBalance(a.address) - aBefore).to.equal(E('0.0017'));
    expect(await ethers.provider.getBalance(fee.address)).to.equal(feeBefore); // no fee
    const r = await pots.getRound(1);
    expect(r.potAmount).to.equal(seed); // seed rolled forward untouched
    expect((await pots.getLastResult(1)).refunded).to.equal(true);
    expect(potBefore - (await ethers.provider.getBalance(await pots.getAddress()))).to.equal(E('0.0017'));
  });

  it('auto-settles an expired round on the next bid (refund case too)', async () => {
    const { pots, a, b } = await deploy();
    await pots.connect(a).dropBid(0, { value: E('0.0001') });
    await time.increase(60);
    const aBefore = await ethers.provider.getBalance(a.address);
    await pots.connect(b).dropBid(0, { value: E('0.0001') });
    expect(await ethers.provider.getBalance(a.address) - aBefore).to.equal(E('0.0001'));
    const r = await pots.getRound(0);
    expect(r.roundId).to.equal(2);
    expect(r.leader).to.equal(b.address);
  });

  it('below-minimum bids revert; empty expired round cannot be finalized', async () => {
    const { pots, a } = await deploy();
    await expect(pots.connect(a).dropBid(0, { value: E('0.00009') })).to.be.revertedWith('PicklePots: Bid below tier minimum');
    await time.increase(60);
    await expect(pots.finalizeRound(0)).to.be.revertedWith('PicklePots: No bids placed in this round');
    await expect(pots.dropBid(9, { value: E('1') })).to.be.revertedWith('PicklePots: Invalid tier');
  });

  it('dropBidFor: session wallet plays, winnings and refunds go to the beneficiary', async () => {
    const { pots, a, b, c } = await deploy();
    // c is the fast session wallet, a is the player's main wallet
    await pots.connect(c).dropBidFor(0, a.address, { value: E('0.0001') });
    await pots.connect(b).dropBid(0, { value: E('0.0001') });
    await pots.connect(c).dropBidFor(0, a.address, { value: E('0.0002') });
    expect((await pots.getRound(0)).leader).to.equal(a.address);
    await time.increase(60);
    const aBefore = await ethers.provider.getBalance(a.address);
    await pots.connect(c).finalizeRound(0);
    expect(await ethers.provider.getBalance(a.address) - aBefore).to.equal(E('0.0004') * 9000n / 10000n);
  });

  it('a winner that rejects ETH cannot freeze the jar; funds are claimable', async () => {
    const { pots, a } = await deploy();
    const bad = await (await ethers.getContractFactory('RejectingPlayer')).deploy();
    await pots.connect(a).dropBid(0, { value: E('0.0001') });
    await bad.bid(await pots.getAddress(), 0, { value: E('0.0002') });
    await time.increase(60);
    await pots.finalizeRound(0); // must not revert
    const badAddr = await bad.getAddress();
    expect(await pots.pending(ethers.ZeroAddress, badAddr)).to.equal(E('0.0003') * 9000n / 10000n);
    expect((await pots.getRound(0)).roundId).to.equal(2);
  });

  it('PKL jar: approve + bid, 90/5/5 split in PKL, solo refund in PKL', async () => {
    const { pots, pkl, fee, a, b } = await deploy();
    const addr = await pots.getAddress();
    await expect(pots.connect(a).dropBid(4, { value: E('1') })).to.be.revertedWith('PicklePots: Use dropBidToken');
    await pkl.connect(a).approve(addr, E('1000'));
    await pkl.connect(b).approve(addr, E('1000'));
    await expect(pots.connect(a).dropBidToken(4, ethers.ZeroAddress, E('5'))).to.be.revertedWith('PicklePots: Bid below tier minimum');
    await pots.connect(a).dropBidToken(4, ethers.ZeroAddress, E('10'));
    await pots.connect(b).dropBidToken(4, ethers.ZeroAddress, E('30'));
    await time.increase(120);
    const bBefore = await pkl.balanceOf(b.address);
    await pots.finalizeRound(4);
    expect(await pkl.balanceOf(b.address) - bBefore).to.equal(E('36'));
    expect(await pkl.balanceOf(fee.address)).to.equal(E('2'));
    expect((await pots.getRound(4)).potAmount).to.equal(E('2'));
    // solo in PKL
    const aBefore = await pkl.balanceOf(a.address);
    await pots.connect(a).dropBidToken(4, ethers.ZeroAddress, E('20'));
    await time.increase(120);
    await pots.finalizeRound(4);
    expect(await pkl.balanceOf(a.address)).to.equal(aBefore); // got the 20 back
    expect((await pots.getRound(4)).potAmount).to.equal(E('2'));
  });

  it('accounting: contract balance always equals current pots + pending', async () => {
    const { pots, a, b, c } = await deploy();
    const addr = await pots.getAddress();
    for (let i = 0; i < 3; i++) {
      await pots.connect(a).dropBid(2, { value: E('0.002') });
      await pots.connect(b).dropBid(2, { value: E('0.003') });
      await pots.connect(c).dropBid(2, { value: E('0.002') });
      await time.increase(100);
      await pots.finalizeRound(2);
    }
    await pots.connect(a).dropBid(0, { value: E('0.0001') });
    let pots_sum = 0n;
    for (let t = 0; t < 4; t++) pots_sum += (await pots.getRound(t)).potAmount;
    expect(await ethers.provider.getBalance(addr)).to.equal(pots_sum);
  });

  it('owner-only admin, 2-step ownership, upgrade works and can be frozen', async () => {
    const { pots, impl, owner, a } = await deploy();
    await expect(pots.connect(a).setFeeRecipient(a.address)).to.be.reverted;
    await expect(pots.connect(a).upgradeToAndCall(await impl.getAddress(), '0x')).to.be.reverted;
    const impl2 = await (await ethers.getContractFactory('PicklePotsV2')).deploy();
    await pots.connect(a).dropBid(0, { value: E('0.0001') });
    await pots.connect(owner).upgradeToAndCall(await impl2.getAddress(), '0x');
    expect((await pots.getRound(0)).totalBids).to.equal(1); // state preserved
    await pots.transferOwnership(a.address);
    expect(await pots.owner()).to.equal(owner.address);
    await pots.connect(a).acceptOwnership();
    expect(await pots.owner()).to.equal(a.address);
    await pots.connect(a).freezeUpgrades();
    await expect(pots.connect(a).upgradeToAndCall(await impl2.getAddress(), '0x')).to.be.revertedWith('PicklePots: upgrades frozen');
  });

  it('implementation cannot be initialized directly; proxy cannot be re-initialized', async () => {
    const { pots, impl, a } = await deploy();
    await expect(impl.initialize(a.address, a.address, ethers.ZeroAddress, ethers.ZeroAddress)).to.be.reverted;
    await expect(pots.initialize(a.address, a.address, ethers.ZeroAddress, ethers.ZeroAddress)).to.be.reverted;
  });
});
