const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = (n) => ethers.parseEther(String(n));

describe("FanOut", function () {
  let fo, owner, host, ann, ben, cara, dan;

  beforeEach(async () => {
    [owner, host, ann, ben, cara, dan] = await ethers.getSigners();
    const F = await ethers.getContractFactory("FanOut");
    fo = await F.deploy();
    await fo.waitForDeployment();
  });

  // 10% to the direct referrer, 5% to theirs, 2% protocol fee.
  async function newCampaign(l1 = 1000, l2 = 500, min = "0.1") {
    await fo.connect(host).createCampaign("Pathfinder launch", l1, l2, E(min));
    return (await fo.campaignCount()) - 1n;
  }

  it("creates a campaign with its commission rates", async () => {
    const id = await newCampaign();
    const c = await fo.getCampaign(id);
    expect(c.owner).to.equal(host.address);
    expect(c.l1Bps).to.equal(1000);
    expect(c.l2Bps).to.equal(500);
    expect(c.open).to.equal(true);
  });

  it("rejects runaway commission, an inverted split and a zero minimum", async () => {
    await expect(fo.connect(host).createCampaign("x", 3000, 2000, E(1))).to.be.revertedWith("commission too high");
    await expect(fo.connect(host).createCampaign("x", 500, 1000, E(1))).to.be.revertedWith("l2 above l1");
    await expect(fo.connect(host).createCampaign("x", 500, 100, 0)).to.be.revertedWith("min must be positive");
    await expect(fo.connect(host).createCampaign("", 500, 100, E(1))).to.be.revertedWith("bad name");
  });

  it("sends everything but the fee to the vault when there is no referrer", async () => {
    const id = await newCampaign();
    await fo.connect(ann).join(id, ethers.ZeroAddress, { value: E(10) });

    const c = await fo.getCampaign(id);
    expect(c.vault).to.equal(E("9.8"));       // 10 minus the 2% fee
    expect(await fo.accumulatedFees()).to.equal(E("0.2"));
    expect(c.participants).to.equal(1);
  });

  it("pays one level up, then two", async () => {
    const id = await newCampaign();
    await fo.connect(ann).join(id, ethers.ZeroAddress, { value: E(1) });
    await fo.connect(ben).join(id, ann.address, { value: E(1) });

    // Ben's contribution: 10% to Ann, nothing above her.
    expect(await fo.earnedBy(id, ann.address)).to.equal(E("0.1"));

    await fo.connect(cara).join(id, ben.address, { value: E(10) });
    // Cara's: 10% to Ben, 5% to Ann.
    expect(await fo.earnedBy(id, ben.address)).to.equal(E(1));
    expect(await fo.earnedBy(id, ann.address)).to.equal(E("0.6")); // 0.1 + 0.5

    const c = await fo.getCampaign(id);
    // 10 - 0.2 fee - 1 l1 - 0.5 l2 = 8.3, plus 0.98 and 0.88 from the first two.
    expect(c.vault).to.equal(E("8.3") + E("0.98") + E("0.88"));
  });

  it("requires a referrer who is already in the campaign, and refuses self-referral", async () => {
    const id = await newCampaign();
    await expect(fo.connect(ben).join(id, ann.address, { value: E(1) })).to.be.revertedWith(
      "referrer not in campaign"
    );
    await expect(fo.connect(ben).join(id, ben.address, { value: E(1) })).to.be.revertedWith(
      "cannot refer yourself"
    );
  });

  it("fixes attribution on the first join and ignores it afterwards", async () => {
    const id = await newCampaign();
    await fo.connect(ann).join(id, ethers.ZeroAddress, { value: E(1) });
    await fo.connect(cara).join(id, ethers.ZeroAddress, { value: E(1) });
    await fo.connect(ben).join(id, ann.address, { value: E(1) });

    // Ben tries to switch his credit to Cara on a later contribution.
    await fo.connect(ben).join(id, cara.address, { value: E(1) });

    expect(await fo.referrerOf(id, ben.address)).to.equal(ann.address);
    expect(await fo.earnedBy(id, ann.address)).to.equal(E("0.2")); // both contributions
    expect(await fo.earnedBy(id, cara.address)).to.equal(0);
    expect((await fo.getCampaign(id)).participants).to.equal(3);
  });

  it("keeps unearned commission in the campaign rather than the protocol", async () => {
    const id = await newCampaign();
    await fo.connect(ann).join(id, ethers.ZeroAddress, { value: E(1) });
    await fo.connect(ben).join(id, ann.address, { value: E(10) });

    // No second level above Ann, so that 5% stays in the vault.
    const c = await fo.getCampaign(id);
    expect(c.vault).to.equal(E("0.98") + E("8.8")); // 10 - 0.2 fee - 1 l1
    expect(await fo.accumulatedFees()).to.equal(E("0.22"));
  });

  it("pays commission on a pull, once", async () => {
    const id = await newCampaign();
    await fo.connect(ann).join(id, ethers.ZeroAddress, { value: E(1) });
    await fo.connect(ben).join(id, ann.address, { value: E(10) });

    await expect(fo.connect(cara).withdrawEarnings(id)).to.be.revertedWith("nothing earned");
    await expect(fo.connect(ann).withdrawEarnings(id)).to.changeEtherBalance(ann, E(1));
    await expect(fo.connect(ann).withdrawEarnings(id)).to.be.revertedWith("nothing earned");
  });

  it("lets the campaign owner draw the vault, and nobody else", async () => {
    const id = await newCampaign();
    await fo.connect(ann).join(id, ethers.ZeroAddress, { value: E(10) });

    await expect(fo.connect(ann).withdrawVault(id)).to.be.revertedWith("not campaign owner");
    await expect(fo.connect(host).withdrawVault(id)).to.changeEtherBalance(host, E("9.8"));
    await expect(fo.connect(host).withdrawVault(id)).to.be.revertedWith("vault empty");
  });

  it("enforces the minimum and the open flag", async () => {
    const id = await newCampaign();
    await expect(fo.connect(ann).join(id, ethers.ZeroAddress, { value: E("0.05") })).to.be.revertedWith(
      "below minimum"
    );
    await fo.connect(host).setOpen(id, false);
    await expect(fo.connect(ann).join(id, ethers.ZeroAddress, { value: E(1) })).to.be.revertedWith(
      "campaign closed"
    );
    await expect(fo.connect(ann).setOpen(id, true)).to.be.revertedWith("not campaign owner");
  });

  it("keeps the campaign owner out of their own funnel", async () => {
    const id = await newCampaign();
    await expect(fo.connect(host).join(id, ethers.ZeroAddress, { value: E(1) })).to.be.revertedWith(
      "owner cannot join"
    );
  });

  it("pauses joining but never a withdrawal", async () => {
    const id = await newCampaign();
    await fo.connect(ann).join(id, ethers.ZeroAddress, { value: E(1) });
    await fo.connect(ben).join(id, ann.address, { value: E(10) });
    await fo.connect(owner).pause();

    await expect(fo.connect(cara).join(id, ann.address, { value: E(1) })).to.be.revertedWithCustomError(
      fo,
      "EnforcedPause"
    );
    await fo.connect(ann).withdrawEarnings(id);
    await fo.connect(host).withdrawVault(id);
  });

  it("previews a split that matches what actually happens", async () => {
    const id = await newCampaign();
    await fo.connect(ann).join(id, ethers.ZeroAddress, { value: E(1) });
    await fo.connect(ben).join(id, ann.address, { value: E(1) });

    const p = await fo.previewSplit(id, ben.address, E(10));
    expect(p.l1Amount).to.equal(E(1));
    expect(p.l2Amount).to.equal(0);
    expect(p.fee).to.equal(E("0.2"));
    expect(p.toVault).to.equal(E("8.8"));

    const before = await fo.earnedBy(id, ann.address);
    await fo.connect(ben).join(id, ethers.ZeroAddress, { value: E(10) });
    expect((await fo.earnedBy(id, ann.address)) - before).to.equal(p.l1Amount);
  });

  it("traces the downline and the upline", async () => {
    const id = await newCampaign();
    await fo.connect(ann).join(id, ethers.ZeroAddress, { value: E(1) });
    await fo.connect(ben).join(id, ann.address, { value: E(1) });
    await fo.connect(cara).join(id, ann.address, { value: E(1) });
    await fo.connect(dan).join(id, ben.address, { value: E(1) });

    expect(await fo.directReferrals(id, ann.address)).to.deep.equal([ben.address, cara.address]);
    const up = await fo.uplineOf(id, dan.address);
    expect(up.l1).to.equal(ben.address);
    expect(up.l2).to.equal(ann.address);
  });

  it("caps the fee and withdraws only fees, owner only", async () => {
    await expect(fo.connect(owner).setFeeBps(900)).to.be.revertedWith("fee too high");

    const id = await newCampaign();
    await fo.connect(ann).join(id, ethers.ZeroAddress, { value: E(10) });

    await expect(fo.connect(ann).withdrawFees(ann.address)).to.be.revertedWithCustomError(
      fo,
      "OwnableUnauthorizedAccount"
    );
    await expect(fo.connect(owner).withdrawFees(owner.address)).to.changeEtherBalance(owner, E("0.2"));

    // The campaign vault survives the sweep.
    expect(await ethers.provider.getBalance(await fo.getAddress())).to.equal(E("9.8"));
    expect(await fo.lockedTotal()).to.equal(E("9.8"));
  });
});
