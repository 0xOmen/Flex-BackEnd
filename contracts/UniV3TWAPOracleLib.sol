//SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-core/contracts/libraries/FixedPoint96.sol";
import "@uniswap/v3-core/contracts/libraries/FullMath.sol";

contract UniV3TwapOracleLib {
    // Returns uint256 TWAP price of a Uniswap pool token1 in terms of token0 i.e. 1 token0 = x token1
    function convertToHumanReadable(
        address _factory,
        address _token0,
        address _token1,
        uint24 _fee,
        uint32 _twapInterval,
        uint8 _token0Decimals
    ) public view returns (uint256) {
        address _poolAddress = IUniswapV3Factory(_factory).getPool(
            _token0,
            _token1,
            _fee
        );
        require(_poolAddress != address(0), "pool doesn't exist");

        uint160 _sqrtPriceX96 = getSqrtTwapX96(_poolAddress, _twapInterval);
        //uint160 priceX96 = getPriceX96FromSqrtPriceX96(_sqrtPriceX96);
        uint256 price = getPriceFromPriceX96(_sqrtPriceX96, _token0Decimals);
        return price;
    }

    //returns time-weighted price which will need to be converted from sqrtPrice to Price
    function getSqrtTwapX96(
        address uniswapV3Pool,
        uint32 twapInterval
    ) public view returns (uint160 sqrtPriceX96) {
        if (twapInterval == 0) {
            // return the current price if twapInterval == 0
            (sqrtPriceX96, , , , , , ) = IUniswapV3Pool(uniswapV3Pool).slot0();
        } else {
            uint32[] memory secondsAgos = new uint32[](2);
            secondsAgos[0] = twapInterval; // from (before)
            secondsAgos[1] = 0; // to (now)

            (int56[] memory tickCumulatives, ) = IUniswapV3Pool(uniswapV3Pool)
                .observe(secondsAgos);

            // tick(imprecise as it's an integer) to price
            sqrtPriceX96 = TickMath.getSqrtRatioAtTick(
                int24((tickCumulatives[1] - tickCumulatives[0]) / twapInterval)
            );
        }
    }

    function getPriceX96FromSqrtPriceX96(
        uint160 sqrtPriceX96
    ) public pure returns (uint256 priceX96) {
        return FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
    }

    function getPriceFromPriceX96(
        uint160 sqrtPriceX96,
        uint8 token0Decimals
    ) internal pure returns (uint256) {
        uint256 numerator1 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        uint256 numerator2 = 10 ** token0Decimals;
        return FullMath.mulDiv(numerator1, numerator2, 1 << 192);
    }

    function getToken0FromPool(
        address _poolAddress
    ) public view returns (address) {
        return IUniswapV3PoolImmutables(_poolAddress).token0();
    }

    function getToken0(
        address _factory,
        address _tokenA,
        address _tokenB,
        uint24 _fee
    ) public view returns (address) {
        address _poolAddress = IUniswapV3Factory(_factory).getPool(
            _tokenA,
            _tokenB,
            _fee
        );
        return IUniswapV3PoolImmutables(_poolAddress).token0();
    }

    function getPoolAddress(
        address _factory,
        address _tokenA,
        address _tokenB,
        uint24 _fee
    ) public view returns (address) {
        return IUniswapV3Factory(_factory).getPool(_tokenA, _tokenB, _fee);
    }
}
