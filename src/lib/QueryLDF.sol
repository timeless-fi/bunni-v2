// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import "../types/IdleBalance.sol";
import {Q96} from "../base/Constants.sol";
import {FullMathX96} from "./FullMathX96.sol";
import {LiquidityAmounts} from "./LiquidityAmounts.sol";
import {roundTick, roundUpFullMulDivResult} from "./Math.sol";
import {ILiquidityDensityFunction} from "../interfaces/ILiquidityDensityFunction.sol";

using FullMathX96 for uint256;
using FixedPointMathLib for uint256;

/// @notice Queries the liquidity density function for the given pool and tick
/// @param key The pool key
/// @param sqrtPriceX96 The current sqrt price of the pool
/// @param tick The current tick of the pool
/// @param arithmeticMeanTick The TWAP oracle value
/// @param ldf The liquidity density function
/// @param ldfParams The parameters for the liquidity density function
/// @param ldfState The current state of the liquidity density function
/// @param balance0 The balance of token0 in the pool
/// @param balance1 The balance of token1 in the pool
/// @param idleBalance The idle balance of the pool, which is removed from the corresponding balance0/balance1
/// when computing totalLiquidity.
/// @return totalLiquidity The total liquidity in the pool
/// @return totalDensity0X96 The total density of token0 in the pool, scaled by Q96
/// @return totalDensity1X96 The total density of token1 in the pool, scaled by Q96
/// @return liquidityDensityOfRoundedTickX96 The liquidity density of the rounded tick, scaled by Q96
/// @return activeBalance0 The active balance of token0 in the pool, which is the amount used by swap liquidity
/// @return activeBalance1 The active balance of token1 in the pool, which is the amount used by swap liquidity
/// @return newLdfState The new state of the liquidity density function
/// @return shouldSurge Whether the pool should surge
function queryLDF(
    PoolKey memory key,
    uint160 sqrtPriceX96,
    int24 tick,
    int24 arithmeticMeanTick,
    ILiquidityDensityFunction ldf,
    bytes32 ldfParams,
    bytes32 ldfState,
    uint256 balance0,
    uint256 balance1,
    IdleBalance idleBalance
)
    view
    returns (
        uint256 totalLiquidity,
        uint256 totalDensity0X96,
        uint256 totalDensity1X96,
        uint256 liquidityDensityOfRoundedTickX96,
        uint256 activeBalance0,
        uint256 activeBalance1,
        bytes32 newLdfState,
        bool shouldSurge
    )
{
    (int24 roundedTick, int24 nextRoundedTick) = roundTick(tick, key.tickSpacing);
    (uint160 roundedTickSqrtRatio, uint160 nextRoundedTickSqrtRatio) =
        (TickMath.getSqrtPriceAtTick(roundedTick), TickMath.getSqrtPriceAtTick(nextRoundedTick));
    uint256 density0RightOfRoundedTickX96;
    uint256 density1LeftOfRoundedTickX96;
    (
        liquidityDensityOfRoundedTickX96,
        density0RightOfRoundedTickX96,
        density1LeftOfRoundedTickX96,
        newLdfState,
        shouldSurge
    ) = ldf.query(key, roundedTick, arithmeticMeanTick, tick, ldfParams, ldfState);

    (uint256 density0OfRoundedTickX96, uint256 density1OfRoundedTickX96) = LiquidityAmounts.getAmountsForLiquidity(
        sqrtPriceX96, roundedTickSqrtRatio, nextRoundedTickSqrtRatio, uint128(liquidityDensityOfRoundedTickX96), true
    );
    totalDensity0X96 = density0RightOfRoundedTickX96 + density0OfRoundedTickX96;
    totalDensity1X96 = density1LeftOfRoundedTickX96 + density1OfRoundedTickX96;

    // modify balance0/balance1 to deduct the idle balance
    // skip this if a surge happens since the idle balance will need to be recalculated
    if (!shouldSurge) {
        (uint256 balance, bool isToken0) = IdleBalanceLibrary.fromIdleBalance(idleBalance);
        if (isToken0) {
            balance0 = subReLU(balance0, balance);
        } else {
            balance1 = subReLU(balance1, balance);
        }
    }

    if (balance0 != 0 || balance1 != 0) {
        bool noToken0 = balance0 == 0 || totalDensity0X96 == 0;
        bool noToken1 = balance1 == 0 || totalDensity1X96 == 0;
        uint256 totalLiquidityEstimate0 = noToken0 ? 0 : balance0.fullMulDiv(Q96, totalDensity0X96);
        uint256 totalLiquidityEstimate1 = noToken1 ? 0 : balance1.fullMulDiv(Q96, totalDensity1X96);
        bool useLiquidityEstimate0 =
            (totalLiquidityEstimate0 < totalLiquidityEstimate1 || totalDensity1X96 == 0) && totalDensity0X96 != 0;
        if (useLiquidityEstimate0) {
            totalLiquidity =
                noToken0 ? 0 : roundUpFullMulDivResult(balance0, Q96, totalDensity0X96, totalLiquidityEstimate0);
            (activeBalance0, activeBalance1) = (
                noToken0 ? 0 : FixedPointMathLib.min(balance0, totalLiquidityEstimate0.fullMulX96(totalDensity0X96)),
                noToken1 ? 0 : FixedPointMathLib.min(balance1, totalLiquidityEstimate0.fullMulX96(totalDensity1X96))
            );
        } else {
            totalLiquidity =
                noToken1 ? 0 : roundUpFullMulDivResult(balance1, Q96, totalDensity1X96, totalLiquidityEstimate1);
            (activeBalance0, activeBalance1) = (
                noToken0 ? 0 : FixedPointMathLib.min(balance0, totalLiquidityEstimate1.fullMulX96(totalDensity0X96)),
                noToken1 ? 0 : FixedPointMathLib.min(balance1, totalLiquidityEstimate1.fullMulX96(totalDensity1X96))
            );
        }
    }
}
