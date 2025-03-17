// This setup uses Hardhat Ignition to manage smart contract deployments.
// Learn more about it at https://hardhat.org/ignition

const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");

const NAME = "FranCode";
const SYMBOL = "FCD";
const CAP = 10_000_000_000;

module.exports = buildModule("TokenModule", (m) => {
  const token = m.contract("Token", [NAME, SYMBOL, CAP]);

  return { token };
});
