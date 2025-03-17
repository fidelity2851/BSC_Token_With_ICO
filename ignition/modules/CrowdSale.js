// This setup uses Hardhat Ignition to manage smart contract deployments.
// Learn more about it at https://hardhat.org/ignition

const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");

const TOKEN = process.env.TOKEN_ADDRESS;
const MAX_PURCHASE_LIMIT = 10_000_000;
const DEFAULT_TOKEN_ADDRESS = process.env.DEFAULT_TOKEN_ADDRESS;
const START_TIME = process.env.START_TIME;
const END_TIME = process.env.END_TIME;

module.exports = buildModule("CrowdSaleModule", (m) => {
    const crowdsale = m.contract("CrowdSale", [TOKEN, DEFAULT_TOKEN_ADDRESS, MAX_PURCHASE_LIMIT, START_TIME, END_TIME]);

    return { crowdsale };
});
