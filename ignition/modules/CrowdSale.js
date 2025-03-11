// This setup uses Hardhat Ignition to manage smart contract deployments.
// Learn more about it at https://hardhat.org/ignition

const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");

const TOKEN = process.env.TOKEN_ADDRESS;
const USDTTOKEN = process.env.USDT_TOKEN_ADDRESS;
const BNBPRICEFEED = process.env.BNB_PRICE_FEED_ADDRESS;
const STARTTIME = process.env.START_TIME;
const ENDTIME = process.env.END_TIME;

module.exports = buildModule("CrowdSaleModule", (m) => {
    const crowdsale = m.contract("CrowdSale", [TOKEN, USDTTOKEN, BNBPRICEFEED, STARTTIME, ENDTIME]);

    return { crowdsale };
});
