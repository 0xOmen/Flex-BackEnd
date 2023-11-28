# Flex
Protocol to escrow user defined contracts and other data with programmatic execution performed by oracles.

Users can define an oracle using either Chainlink feeds or UniswapV3 oracles.  Chainlink has price feeds for most major cryptocurrencies, FX currencies, and NFT floor prices.  Uniswap oracles can be used for long-tail assets however they are more prone to manipulation.  If the items being compared do not have a direct oracle then two oracles of the same type (e.g. both Chainlink or both Uniswap) can be defined.  For example, to compare price of Token A vs Token B where no A/B oracle exists, a user can queiry Chainlink oracles A/WETH and B/WETH.  

-Beware of Chainlink oracle dynamics.  Chainlink price oracles generally update off of 2 triggers: price deviations of 0.5% or more -or- every 3600 seconds. This can causes errors if high precision is needed.
-If calling directly to the smart contract (i.e. not via the frontend), users must be very careful how they define A/B prices and oracles.
-Uniswap oracles on Goerli are broken and should not be used.

### DEFINITIONS
**Maker** - escrow creator  
**Taker** - user who accepts terms of escrow  
**CollateralToken** - Token used as collateral to settle a escrow  
**PriceLine** - Price at which the escrow is determined 

Currently any token can be used as the 'CollateralToken' (collateral) in the contract.  The frontend limits users to a small subset of tokens.  Rebase tokens should not be used as the contract accounting system does not account for rebases.  There is no AllowList preventing use of Rebase Tokens as collateral if users interact directly with the smart contract and funds can be lost.  

Both the 'Maker' and 'Taker' have to use the same CollateralToken for a bet.

Currently, anyone can close an escrow once all necessary checks are cleared. Chainlink Automation will automatically close escrows once all necessary conditions are met.  

Maker can define taker address as "0x0000000000000000000000000000000000000000" allowing anyone to be Taker or they can limit it to a specific address.  On the frontend this is handled for the users with a toggle button.

The Flex smart contract interfaces with a custom built UniV3TwapOracle smart contract to convert Uniswap oracle price to a human readable format and determine which token is the base token (aka Token0) in Uniswap pools.

### Contracts - Goerli
**Flex** - 0x81cD61426F8440576Ad44f462442393E865Bfa26
**UniV3TwapOracle** - 0xDC4BA11C0Cd22A10CC468A42FFB58cF0540C36cB
