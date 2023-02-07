const {
  time,
  loadFixture,
} = require("@nomicfoundation/hardhat-network-helpers");
const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");
const { expect } = require("chai");

describe("Staking", function () {

  let stakingToken, rewardToken, omniaStaking, account0, account1, account2;

  async function deploy() {
    [account0, account1, account2] = await ethers.getSigners();
    const StakingToken = await ethers.getContractFactory("Token");
    const RewardToken = await ethers.getContractFactory("Token");
    stakingToken = await StakingToken.deploy('Staking Token', 'STT');
    rewardToken = await RewardToken.deploy('Reward Token', 'RWT');
    const OmniaStaking = await ethers.getContractFactory("OmniaStaking");
    omniaStaking = await OmniaStaking.deploy(stakingToken.address, rewardToken.address);  
  }

  describe("Deployment, fill the balances, check setters and getters", function () {

    it("Deploy", async function () {
      await loadFixture(deploy);
    });

    it("Setters", async function () {

      const apysArray = [[1427, 1000, 2000], [500, 600], [1234]]; // SLA IDs (0 - Networks IDs (0, 1, 2), 1 - Networks IDs (0, 1), 2 - Networks IDs (0))
      await omniaStaking.setIntrestRates(apysArray);
                                // SLA id, Net ID
      expect(await omniaStaking.getIntrestRates(0, 0)).to.equal(1427);
      expect(await omniaStaking.getIntrestRates(0, 2)).to.equal(2000);
      expect(await omniaStaking.getIntrestRates(2, 0)).to.equal(1234);

      await omniaStaking.setPenalityDays(account1.address, 10);
      await omniaStaking.setPenalityDays(account2.address, 100);

    });

    it("Should set the right owner for Token & Staking", async function () {
      expect(await stakingToken.owner()).to.equal(account0.address);
      expect(await rewardToken.owner()).to.equal(account0.address);
      const role = hre.ethers.utils.keccak256(hre.ethers.utils.toUtf8Bytes("ADMIN_ROLE"));
      expect(await omniaStaking.hasRole(role, account0.address)).to.equal(true);
    });

    it("Should get the right balances", async function () {

      const amount = hre.ethers.utils.parseEther("1000000000");

      await rewardToken.transfer(omniaStaking.address, "1500000000000000000000000000000"); // fill the staking contract balance with reward tokens
      expect(await rewardToken.balanceOf(omniaStaking.address)).to.equal("1500000000000000000000000000000");

      await stakingToken.transfer(account1.address, amount);
      await stakingToken.transfer(account2.address, amount);
      expect(await stakingToken.balanceOf(account1.address)).to.equal(amount);
      expect(await stakingToken.balanceOf(account2.address)).to.equal(amount);

    });

  });

  describe("Stake", function () {

    it("Approve Tokens for Staking SC", async function () {

      const amount = hre.ethers.utils.parseEther("1000000000");
      await stakingToken.approve(omniaStaking.address, amount); 
      await stakingToken.connect(account1).approve(omniaStaking.address, amount); 
      await stakingToken.connect(account2).approve(omniaStaking.address, amount);  

      expect(await stakingToken.allowance(account0.address, omniaStaking.address)).to.equal(amount);
      expect(await stakingToken.allowance(account1.address, omniaStaking.address)).to.equal(amount);
      expect(await stakingToken.allowance(account2.address, omniaStaking.address)).to.equal(amount);

    });

    it("Stake for 3 accounts", async function () {

      const amount10k = hre.ethers.utils.parseEther("10000");
      const amount20k = hre.ethers.utils.parseEther("20000");
      const amount30k = hre.ethers.utils.parseEther("30000");

      // stake(amount, stakingPeiodDays, _slaID, _networkID, _rps)
      await omniaStaking.connect(account1).stake(amount10k, 365, 1, 1, 900); // account1
      await omniaStaking.connect(account2).stake(amount10k, 365, 2, 0, 500); // account2

      // await omniaStaking.changeSLAparams(account0.address, 1000, 0, 0); // staker, rps, slaID, networkID
      await expect(omniaStaking.stake(amount10k, 365, 0, 0, 1000)).to.emit(omniaStaking, "tokensStaked").withArgs(account0.address, amount10k, anyValue, 365, 1000, 0, 0);

    });

    it("Check staking reward", async function () {
      
      let term = 365; // Number of days of months (depends from frequency used in contract)
      let penDays = 0; // Num of penality days
      let base = 10000; // Initial staked amount
      let apr = 1427; // APR % (Depends from percentFraction) // intrest rate from APY https://www.axosbank.com/Tools/Calculators/APY-Calculator
      let rps = 1000;
      const percentFraction = 4;

      const compound = await omniaStaking.compound(base, apr, term, penDays, rps, percentFraction);
      console.log('compound', BigInt(compound));
      const ownReward = await omniaStaking.checkReward();
      console.log('ownReward', BigInt(ownReward));

      expect(await omniaStaking.compound(base, apr, term, penDays, rps, percentFraction)).to.equal(BigInt(1533));
      term = 180;
      expect(await omniaStaking.compound(base, apr, term, penDays, rps, percentFraction)).to.equal(BigInt(728));
      term = 90;
      expect(await omniaStaking.compound(base, apr, term, penDays, rps, percentFraction)).to.equal(BigInt(358));
      term = 60;
      expect(await omniaStaking.compound(base, apr, term, penDays, rps, percentFraction)).to.equal(BigInt(237));
      term = 365;
      penDays = 180;
      expect(await omniaStaking.compound(base, apr, term, penDays, rps, percentFraction)).to.equal(BigInt(1286));
      apr = 1019;      
      penDays = 0;
      expect(await omniaStaking.compound(base, apr, term, penDays, rps, percentFraction)).to.equal(BigInt(1072));

    });

  });

  describe("claimReward", async function () {

    it("Claim Reward", async function () {

      await expect(omniaStaking.claimReward()).to.be.revertedWith("Nothing to claim");

      let now = await time.latest();
      let newTime = now + 30 * 86400;
      await time.increaseTo(newTime);

      let balOfStaking = await rewardToken.balanceOf(omniaStaking.address);
      console.log('balOfStaking before claim', BigInt(balOfStaking));
      let balOfUser = await rewardToken.balanceOf(account0.address);
      console.log('balOfUser before claim', BigInt(balOfUser));
      await omniaStaking.claimReward();
      balOfStaking = await rewardToken.balanceOf(omniaStaking.address);
      console.log('balOfStaking after claim', BigInt(balOfStaking));
      balOfUser = await rewardToken.balanceOf(account0.address);
      console.log('balOfUser after claim', BigInt(balOfUser));

      const ownReward = await omniaStaking.checkReward();
      console.log('ownReward', BigInt(ownReward));
      await expect(omniaStaking.claimReward()).to.be.revertedWith("Nothing to claim");

      newTime = newTime + 365 * 86400;
      await time.increaseTo(newTime);
      
      await omniaStaking.claimReward();
      balOfStaking = await rewardToken.balanceOf(omniaStaking.address);
      console.log('balOfStaking after claim', BigInt(balOfStaking));
      balOfUser = await rewardToken.balanceOf(account0.address);
      console.log('balOfUser after claim', BigInt(balOfUser));

      await expect(omniaStaking.claimReward()).to.be.revertedWith("Nothing to claim");
      newTime = newTime + 30 * 86400;
      await time.increaseTo(newTime);
      await expect(omniaStaking.claimReward()).to.be.revertedWith("Nothing to claim");

    });  

  });

  describe("Unstake", async function () {

    it("Unstake", async function () {

      await omniaStaking.unstake();

    });

  });



    
});
