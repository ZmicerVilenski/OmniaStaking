
const hre = require("hardhat");

async function main() {
  const Staking = await hre.ethers.getContractFactory("OmniaStaking");
  const staking = await Staking.deploy();
  let tx = await staking.deployed();
  console.log(`Staking deployed to ${staking.address}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
