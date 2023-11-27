// import ethers via hardhat
const { ethers, run, network } = require("hardhat")

async function main() {
    const initialProtocolFee = "0005"
    const uniV3FactoryAddress = "0x1F98431c8aD98523631AE4a59f267346ea31F984" //Goerli UniV3 Factory address

    //be sure to specify correct UniV3TWAPOracle name/file!!!
    const UniTwapOracleFactory =
        await ethers.getContractFactory("UniV3TwapOracleLib")
    console.log("Deploying Contract.....")
    const uniOracle = await UniTwapOracleFactory.deploy()
    await uniOracle.waitForDeployment()
    const uniOracleContractAddress = await uniOracle.getAddress()
    console.log(`Deployed contract to: ${uniOracleContractAddress}`)

    const EscrowFactory = await ethers.getContractFactory("Flex")
    console.log("Deploying Contract.....")
    const flex = await EscrowFactory.deploy(
        initialProtocolFee,
        uniOracleContractAddress,
        uniV3FactoryAddress,
    )
    await flex.waitForDeployment()
    const contractAddress = await flex.getAddress()
    console.log(`Deployed contract to: ${contractAddress}`)

    if (network.config.chainId !== 31337 && process.env.ETHERSCAN_API_KEY) {
        await flex.deploymentTransaction().wait(6)
        await verify(uniOracleContractAddress, [])
        await verify(contractAddress, [
            initialProtocolFee,
            uniOracleContractAddress,
            uniV3FactoryAddress,
        ])
    }
}

async function verify(contractAddress, args) {
    console.log("Verifying contract...")
    //this section may not run due to constructor arguments
    await run("verify:verify", {
        address: contractAddress,
        constructorArguments: args,
    })
}

main().catch((error) => {
    console.error(error)
    process.exitCode = 1
})
