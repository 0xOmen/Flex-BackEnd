require("@nomicfoundation/hardhat-toolbox")
require("@openzeppelin/hardhat-upgrades")
require("dotenv").config()

/** @type import('hardhat/config').HardhatUserConfig */

const GOERLI_RPC_URL = process.env.GOERLI_RPC_URL
const PRIVATE_KEY = process.env.PRIVATE_KEY
const OPTIMISM_RPC_URL = process.env.OPTIMISM_RPC_URL
const OMEN_TEST_PRIVATE_KEY = process.env.OMEN_TEST_PRIVATE_KEY
const ETHERSCAN_API_KEY = process.env.ETHERSCAN_API_KEY
const OPTIMISTIC_ETHERSCAN_API_KEY = process.env.OPTIMISTIC_ETHERSCAN_API_KEY

module.exports = {
    defaultNetwork: "hardhat",
    networks: {
        //to deploy to Goerli in terminal: yarn hardhat run scripts/deploy.js --network goerli
        goerli: {
            url: GOERLI_RPC_URL,
            accounts: [PRIVATE_KEY],
            chainId: 5,
        },

        //to deploy to Optimism in terminal: yarn hardhat run scripts/deploy.js --network optimism
        optimism: {
            url: OPTIMISM_RPC_URL,
            accounts: [OMEN_TEST_PRIVATE_KEY],
            chainId: 10,
            gasPrice: 16000000,
        },

        //run yarn hardhat node --> to spin up a node in terminal that persists
        //run yarn hardhat run scripts/deploy.js --network localhost --> to run scripts on localhost
        localhost: {
            url: "http://127.0.0.1:8545/",
            chainId: 31337,
        },
    },
    solidity: {
        compilers: [
            { version: "0.8.20" },
            { version: "0.6.8", settings: {} },
            { version: "0.7.6", settings: {} },
        ],
    },
    etherscan: {
        apiKey: ETHERSCAN_API_KEY,
    },

    optimisticEtherscan: {
        apiKey: OPTIMISTIC_ETHERSCAN_API_KEY,
    },
}
