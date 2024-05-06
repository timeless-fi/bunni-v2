// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import {console2} from "forge-std/console2.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager, PoolKey} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import "./Math.sol";
import "../base/Constants.sol";
import {queryLDF} from "./QueryLDF.sol";
import {LiquidityAmounts} from "./LiquidityAmounts.sol";
import {ILiquidityDensityFunction} from "../interfaces/ILiquidityDensityFunction.sol";

library BunniSwapMath {
    using TickMath for int24;
    using SafeCastLib for uint256;
    using FixedPointMathLib for uint256;

    struct BunniComputeSwapInput {
        PoolKey key;
        uint256 totalLiquidity;
        uint256 liquidityDensityOfRoundedTickX96;
        uint256 totalDensity0X96;
        uint256 totalDensity1X96;
        uint160 sqrtPriceX96;
        int24 currentTick;
        ILiquidityDensityFunction liquidityDensityFunction;
        int24 arithmeticMeanTick;
        bool useTwap;
        bytes32 ldfParams;
        bytes32 ldfState;
        IPoolManager.SwapParams swapParams;
    }

    /// @notice Computes the result of a swap given the input parameters
    /// @param input The input parameters for the swap
    /// @param balance0 The balance of token0 in the pool
    /// @param balance1 The balance of token1 in the pool
    /// @return updatedSqrtPriceX96 The updated sqrt price after the swap
    /// @return updatedTick The updated tick after the swap
    /// @return inputAmount The input amount of the swap
    /// @return outputAmount The output amount of the swap
    function computeSwap(BunniComputeSwapInput memory input, uint256 balance0, uint256 balance1)
        external
        view
        returns (uint160 updatedSqrtPriceX96, int24 updatedTick, uint256 inputAmount, uint256 outputAmount)
    {
        uint256 outputTokenBalance = input.swapParams.zeroForOne ? balance1 : balance0;
        if (input.swapParams.amountSpecified < 0 && uint256(-input.swapParams.amountSpecified) > outputTokenBalance) {
            // exact output swap where the requested output amount exceeds the output token balance
            // change swap to an exact output swap where the output amount is the output token balance
            input.swapParams.amountSpecified = -outputTokenBalance.toInt256();
        }

        // compute first pass result
        (updatedSqrtPriceX96, updatedTick, inputAmount, outputAmount) = _computeSwap(input);

        // ensure that the output amount is lte the output token balance
        if (outputAmount > outputTokenBalance) {
            // exactly output the output token's balance
            // need to recompute swap
            input.swapParams.amountSpecified = -outputTokenBalance.toInt256();
            (updatedSqrtPriceX96, updatedTick, inputAmount, outputAmount) = _computeSwap(input);

            if (outputAmount > outputTokenBalance) {
                // somehow the output amount is still greater than the balance due to rounding errors
                // just set outputAmount to the balance
                outputAmount = outputTokenBalance;
            }
        }
    }

    function _computeSwap(BunniComputeSwapInput memory input)
        private
        view
        returns (uint160 updatedSqrtPriceX96, int24 updatedTick, uint256 inputAmount, uint256 outputAmount)
    {
        // bound sqrtPriceLimit so that we never end up at an invalid rounded tick
        (uint160 minSqrtPrice, uint160 maxSqrtPrice) = (
            TickMath.minUsableTick(input.key.tickSpacing).getSqrtRatioAtTick(),
            TickMath.maxUsableTick(input.key.tickSpacing).getSqrtRatioAtTick()
        );
        uint160 sqrtPriceLimitX96 = input.swapParams.sqrtPriceLimitX96;
        if (
            (input.swapParams.zeroForOne && sqrtPriceLimitX96 < minSqrtPrice)
                || (!input.swapParams.zeroForOne && sqrtPriceLimitX96 >= maxSqrtPrice)
        ) {
            sqrtPriceLimitX96 = input.swapParams.zeroForOne ? minSqrtPrice : maxSqrtPrice - 1;
        }

        // compute updated current tick liquidity
        // totalLiquidity could exceed uint128 so .toUint128() is used
        uint128 updatedRoundedTickLiquidity =
            ((input.totalLiquidity * input.liquidityDensityOfRoundedTickX96) >> 96).toUint128();

        // initialize input and output amounts based on initial info
        bool exactIn = input.swapParams.amountSpecified >= 0;
        inputAmount = exactIn ? uint256(input.swapParams.amountSpecified) : 0;
        outputAmount = exactIn ? 0 : uint256(-input.swapParams.amountSpecified);

        // handle the special case when we don't cross rounded ticks
        {
            uint160 naiveSwapNextSqrtPriceX96;
            if (updatedRoundedTickLiquidity != 0) {
                naiveSwapNextSqrtPriceX96 = exactIn
                    ? SqrtPriceMath.getNextSqrtPriceFromInput(
                        input.sqrtPriceX96, updatedRoundedTickLiquidity, inputAmount, input.swapParams.zeroForOne
                    )
                    : SqrtPriceMath.getNextSqrtPriceFromOutput(
                        input.sqrtPriceX96, updatedRoundedTickLiquidity, outputAmount, input.swapParams.zeroForOne
                    );
            }
            (int24 roundedTick, int24 nextRoundedTick) = roundTick(input.currentTick, input.key.tickSpacing);
            (uint160 roundedTickSqrtRatio, uint160 nextRoundedTickSqrtRatio) =
                (TickMath.getSqrtRatioAtTick(roundedTick), TickMath.getSqrtRatioAtTick(nextRoundedTick));
            if (
                updatedRoundedTickLiquidity != 0
                    && (
                        (input.swapParams.zeroForOne && naiveSwapNextSqrtPriceX96 >= roundedTickSqrtRatio)
                            || (!input.swapParams.zeroForOne && naiveSwapNextSqrtPriceX96 < nextRoundedTickSqrtRatio)
                    )
            ) {
                // swap doesn't cross rounded tick
                updatedSqrtPriceX96 =
                    _boundSqrtPriceByLimit(naiveSwapNextSqrtPriceX96, sqrtPriceLimitX96, input.swapParams.zeroForOne);

                outputAmount = exactIn
                    ? (
                        input.swapParams.zeroForOne
                            ? SqrtPriceMath.getAmount1Delta(
                                input.sqrtPriceX96, updatedSqrtPriceX96, updatedRoundedTickLiquidity, false
                            )
                            : SqrtPriceMath.getAmount0Delta(
                                input.sqrtPriceX96, updatedSqrtPriceX96, updatedRoundedTickLiquidity, false
                            )
                    )
                    : outputAmount;
                inputAmount = !exactIn
                    ? (
                        input.swapParams.zeroForOne
                            ? SqrtPriceMath.getAmount0Delta(
                                input.sqrtPriceX96, updatedSqrtPriceX96, updatedRoundedTickLiquidity, true
                            )
                            : SqrtPriceMath.getAmount1Delta(
                                input.sqrtPriceX96, updatedSqrtPriceX96, updatedRoundedTickLiquidity, true
                            )
                    )
                    : inputAmount;

                updatedTick = TickMath.getTickAtSqrtRatio(updatedSqrtPriceX96);

                // early return
                return (updatedSqrtPriceX96, updatedTick, inputAmount, outputAmount);
            }
        }

        // swap crosses rounded tick
        // need to use LDF to compute the swap
        (uint256 currentActiveBalance0, uint256 currentActiveBalance1) = (
            input.totalDensity0X96.fullMulDiv(input.totalLiquidity, Q96),
            input.totalDensity1X96.fullMulDiv(input.totalLiquidity, Q96)
        );

        // compute updated sqrt ratio & tick
        {
            uint256 inverseCumulativeAmountFnInput;
            if (exactIn) {
                // exact input swap
                inverseCumulativeAmountFnInput = input.swapParams.zeroForOne
                    ? currentActiveBalance0 + inputAmount
                    : currentActiveBalance1 + inputAmount;
            } else {
                // exact output swap
                inverseCumulativeAmountFnInput = input.swapParams.zeroForOne
                    ? currentActiveBalance1 - (outputAmount = FixedPointMathLib.min(outputAmount, currentActiveBalance1))
                    : currentActiveBalance0 - (outputAmount = FixedPointMathLib.min(outputAmount, currentActiveBalance0));
            }

            (bool success, int24 updatedRoundedTick, uint256 cumulativeAmount, uint128 swapLiquidity) = input
                .liquidityDensityFunction
                .computeSwap(
                input.key,
                inverseCumulativeAmountFnInput,
                input.totalLiquidity,
                input.swapParams.zeroForOne,
                exactIn,
                input.arithmeticMeanTick,
                input.currentTick,
                input.useTwap,
                input.ldfParams,
                input.ldfState
            );

            if (success && swapLiquidity != 0) {
                // use Uniswap math to compute updated sqrt price
                uint160 startSqrtPriceX96 = TickMath.getSqrtRatioAtTick(updatedRoundedTick);
                updatedSqrtPriceX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                    startSqrtPriceX96,
                    swapLiquidity,
                    inverseCumulativeAmountFnInput - cumulativeAmount,
                    exactIn == input.swapParams.zeroForOne
                );

                updatedTick = TickMath.getTickAtSqrtRatio(updatedSqrtPriceX96);
            } else {
                // liquidity is insufficient to handle all of the input/output tokens
                (updatedTick, updatedSqrtPriceX96) = input.swapParams.zeroForOne
                    ? (TickMath.MIN_TICK, TickMath.MIN_SQRT_RATIO)
                    : (TickMath.MAX_TICK, TickMath.MAX_SQRT_RATIO);
            }

            // bound sqrt price by limit
            updatedSqrtPriceX96 =
                _boundSqrtPriceByLimit(updatedSqrtPriceX96, sqrtPriceLimitX96, input.swapParams.zeroForOne);
            if (updatedSqrtPriceX96 == sqrtPriceLimitX96) {
                updatedTick = TickMath.getTickAtSqrtRatio(updatedSqrtPriceX96);
            }
        }

        // compute input and output token amounts
        (, uint256 totalDensity0X96, uint256 totalDensity1X96,,,) = queryLDF({
            key: input.key,
            sqrtPriceX96: updatedSqrtPriceX96,
            tick: updatedTick,
            arithmeticMeanTick: input.arithmeticMeanTick,
            useTwap: input.useTwap,
            ldf: input.liquidityDensityFunction,
            ldfParams: input.ldfParams,
            ldfState: input.ldfState,
            balance0: 0,
            balance1: 0
        });
        (uint256 updatedActiveBalance0, uint256 updatedActiveBalance1) = (
            totalDensity0X96.fullMulDivUp(input.totalLiquidity, Q96),
            totalDensity1X96.fullMulDivUp(input.totalLiquidity, Q96)
        );

        (inputAmount, outputAmount) = input.swapParams.zeroForOne
            ? (
                updatedActiveBalance0 - currentActiveBalance0,
                currentActiveBalance1 < updatedActiveBalance1 ? 0 : currentActiveBalance1 - updatedActiveBalance1
            )
            : (
                updatedActiveBalance1 - currentActiveBalance1,
                currentActiveBalance0 < updatedActiveBalance0 ? 0 : currentActiveBalance0 - updatedActiveBalance0
            );

        if (exactIn && inputAmount == uint256(input.swapParams.amountSpecified) + 1) {
            // exact input swap where the input amount exceeds the amount specified
            (inputAmount, outputAmount) = (uint256(input.swapParams.amountSpecified), outputAmount - 1);
        }
    }

    function _boundSqrtPriceByLimit(uint160 sqrtPriceX96, uint160 sqrtPriceLimitX96, bool zeroForOne)
        private
        pure
        returns (uint160)
    {
        if ((zeroForOne && sqrtPriceLimitX96 > sqrtPriceX96) || (!zeroForOne && sqrtPriceLimitX96 < sqrtPriceX96)) {
            return sqrtPriceLimitX96;
        }
        return sqrtPriceX96;
    }
}
