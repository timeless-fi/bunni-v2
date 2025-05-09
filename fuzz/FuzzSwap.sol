// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

import "../src/lib/Math.sol";
import {ShiftMode} from "../src/ldf/ShiftMode.sol";
import {ILiquidityDensityFunction} from "../src/interfaces/ILiquidityDensityFunction.sol";
import {UniformDistribution} from "../src/ldf/UniformDistribution.sol";
import {GeometricDistribution} from "../src/ldf/GeometricDistribution.sol";
import {DoubleGeometricDistribution} from "../src/ldf/DoubleGeometricDistribution.sol";
import {CarpetedGeometricDistribution} from "../src/ldf/CarpetedGeometricDistribution.sol";
import {CarpetedDoubleGeometricDistribution} from "../src/ldf/CarpetedDoubleGeometricDistribution.sol";
import {LDFType} from "../src/types/LDFType.sol";

import "./FuzzHelper.sol";
import "../src/lib/BunniSwapMath.sol";
import "./PropertiesAsserts.sol";
import "forge-std/console.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

error Overflow();

// Before running this with medusa, change the external functions of BunniSwapMath to internals
// and calldata arguments to memory
contract FuzzSwap is FuzzHelper, PropertiesAsserts {
    using TickMath for *;
    using FixedPointMathLib for *;
    using IdleBalanceLibrary for *;

    uint24 internal constant MIN_SWAP_FEE = 1;
    uint8 internal constant NUM_LDFS = 5;
    uint256 internal constant MAX_PROFIT = 500;

    // Invariant: Users should not be able to get free output tokens
    //            for zero input tokens when amountSpecified is non-zero
    //            for a given valid pool state.
    // Issue: TOB-BUNNI-15
    function test_free_or_loss_of_tokens_during_swap(
        int24 tickSpacing,
        uint64 balance0,
        uint64 balance1,
        int64 amountSpecified,
        uint160 sqrtPriceLimit,
        int24 currentTick,
        bool zeroForOne,
        bytes8 ldfSeed
    ) public {
        (tickSpacing, amountSpecified, currentTick) = _processInputs(tickSpacing, amountSpecified, currentTick);

        if (amountSpecified == 0) return;

        // Set up LDF
        _setUpLDF(ldfSeed, tickSpacing);

        // Initialize parameters before swapinng
        (BunniSwapMath.BunniComputeSwapInput memory input1,) =
            _compute_swap(tickSpacing, balance0, balance1, amountSpecified, sqrtPriceLimit, currentTick, zeroForOne);

        // avoid edge case where the active balance of the output token is 0
        // or if the output token's balance is less than requested in an exact output swap
        if (
            (zeroForOne && input1.currentActiveBalance1 == 0) || (!zeroForOne && input1.currentActiveBalance0 == 0)
                || input1.totalLiquidity == 0
                || (
                    amountSpecified > 0
                        && uint64(amountSpecified) > (zeroForOne ? input1.currentActiveBalance1 : input1.currentActiveBalance0)
                )
        ) {
            return;
        }

        try this.swap(input1) returns (
            uint160 updatedSqrtPriceX96, int24 updatedTick, uint256 inputAmount0, uint256 outputAmount0
        ) {
            if (outputAmount0 > 0 && inputAmount0 == 0) {
                assertWithMsg(false, "Users get free tokens");
            }
        } catch Panic(uint256) /*errorCode*/ {
            // This is executed in case of a panic,
            // i.e. a serious error like division by zero
            // or overflow. The error code can be used
            // to determine the kind of error.
            return;
        } catch (bytes memory reason) {
            emit LogBytes(reason);
            return;
        }
    }

    // Invariant: THe sqrt price should move in the direction specified by the zeroForOne flag.
    function swap_should_move_sqrt_price_in_correct_direction(
        int24 tickSpacing,
        uint64 balance0,
        uint64 balance1,
        int64 amountSpecified,
        uint160 sqrtPriceLimit,
        int24 currentTick,
        bool zeroForOne,
        bytes8 ldfSeed
    ) public {
        (tickSpacing, amountSpecified, currentTick) = _processInputs(tickSpacing, amountSpecified, currentTick);

        if (amountSpecified == 0) return;

        // Set up LDF
        _setUpLDF(ldfSeed, tickSpacing);

        // Initialize parameters before swapinng
        (BunniSwapMath.BunniComputeSwapInput memory input1, IdleBalance idleBalance) =
            _compute_swap(tickSpacing, balance0, balance1, amountSpecified, sqrtPriceLimit, currentTick, zeroForOne);

        // avoid edge case where the active balance of the output token is 0
        if (
            (zeroForOne && input1.currentActiveBalance1 == 0) || (!zeroForOne && input1.currentActiveBalance0 == 0)
                || input1.totalLiquidity == 0
        ) {
            return;
        }

        try this.swap(input1) returns (
            uint160 updatedSqrtPriceX96, int24 updatedTick, uint256 inputAmount, uint256 outputAmount
        ) {
            if (inputAmount == 0 || outputAmount == 0) return;
            if (zeroForOne) {
                assertLte(
                    updatedSqrtPriceX96, currentTick.getSqrtPriceAtTick(), "sqrtPriceX96 should be less than or equal"
                );
                assertLte(updatedTick, currentTick, "tick should be less than or equal");
            } else {
                assertGte(
                    updatedSqrtPriceX96,
                    currentTick.getSqrtPriceAtTick(),
                    "sqrtPriceX96 should be greater than or equal"
                );
                assertGte(updatedTick, currentTick, "tick should be greater than or equal");
            }
        } catch Panic(uint256) {
            // This is executed in case of a panic,
            // i.e. a serious error like division by zero
            // or overflow. The error code can be used
            // to determine the kind of error.
            //assert(false);
            return;
        } catch (bytes memory reason) {
            emit LogBytes(reason);
            return;
        }
    }

    // Invariant: Users should not be able to gain any tokens through round trip swaps.
    // Issue: TOB-BUNNI-16
    // This test fails only if the swap fee is zero.
    function test_compare_swap_with_reverse_swap_with_zeroForOne_vs_oneForZero(
        int24 tickSpacing,
        uint64 balance0,
        uint64 balance1,
        int64 amountSpecified,
        uint160 sqrtPriceLimit,
        int24 currentTick,
        uint24 fee,
        bool zeroForOne,
        bytes8 ldfSeed
    ) public {
        (tickSpacing, amountSpecified, currentTick) = _processInputs(tickSpacing, amountSpecified, currentTick);

        if (amountSpecified == 0) return;

        fee = uint24(clampBetween(fee, MIN_SWAP_FEE, SWAP_FEE_BASE));

        console2.log("fee", fee);

        // Set up LDF
        _setUpLDF(ldfSeed, tickSpacing);

        // Initialize parameters before swapinng
        (BunniSwapMath.BunniComputeSwapInput memory input1, IdleBalance idleBalance) =
            _compute_swap(tickSpacing, balance0, balance1, amountSpecified, sqrtPriceLimit, currentTick, zeroForOne);

        // avoid edge case where the active balance of the output token is 0
        // or if the output token's balance is less than requested in an exact output swap
        if (
            (zeroForOne && input1.currentActiveBalance1 == 0) || (!zeroForOne && input1.currentActiveBalance0 == 0)
                || input1.totalLiquidity == 0
                || (
                    amountSpecified > 0
                        && uint64(amountSpecified) > (zeroForOne ? input1.currentActiveBalance1 : input1.currentActiveBalance0)
                )
        ) {
            return;
        }

        if (input1.totalLiquidity < 1e3) return;

        try this.swap(input1) returns (
            uint160 updatedSqrtPriceX96, int24 updatedTick, uint256 inputAmount0, uint256 outputAmount0
        ) {
            // apply fee
            bool exactIn = amountSpecified < 0;
            if (exactIn) {
                inputAmount0 = FixedPointMathLib.max(inputAmount0, uint64(-amountSpecified));
                uint256 swapFeeAmount = outputAmount0.mulDivUp(fee, SWAP_FEE_BASE);
                outputAmount0 -= swapFeeAmount;
            } else {
                outputAmount0 = FixedPointMathLib.min(outputAmount0, uint64(amountSpecified));
                uint256 swapFeeAmount = inputAmount0.mulDivUp(fee, SWAP_FEE_BASE - fee);
                inputAmount0 += swapFeeAmount;
            }

            if (inputAmount0 != uint64(inputAmount0) || outputAmount0 != uint64(outputAmount0)) return;

            BunniSwapMath.BunniComputeSwapInput memory input2 = _compute_swap(
                tickSpacing,
                uint64(balance0 + inputAmount0),
                uint64(balance1 - outputAmount0),
                -amountSpecified,
                input1.sqrtPriceX96, // sqrtPriceLimit
                updatedTick,
                !zeroForOne,
                updatedSqrtPriceX96,
                idleBalance
            );
            // avoid edge case where the active balance of the output token is 0
            // or if the output token's balance is less than requested in an exact output swap
            if (
                (zeroForOne && input2.currentActiveBalance1 == 0) || (!zeroForOne && input2.currentActiveBalance0 == 0)
                    || input2.totalLiquidity == 0
                    || (
                        amountSpecified > 0
                            && uint64(amountSpecified)
                                > (zeroForOne ? input2.currentActiveBalance1 : input2.currentActiveBalance0)
                    )
            ) {
                return;
            }
            input2.swapParams.amountSpecified = exactIn ? -int256(outputAmount0) : int256(inputAmount0);

            if (input2.swapParams.amountSpecified == 0) return;

            (uint160 updatedSqrtPriceX960, int24 updatedTick0, uint256 inputAmount1, uint256 outputAmount1) =
                this.swap(input2);

            // apply fee
            if (exactIn) {
                inputAmount1 = FixedPointMathLib.max(inputAmount1, uint256(-input2.swapParams.amountSpecified));
                uint256 swapFeeAmount = outputAmount1.mulDivUp(fee, SWAP_FEE_BASE);
                outputAmount1 -= swapFeeAmount;
            } else {
                outputAmount1 = FixedPointMathLib.min(outputAmount1, uint256(input2.swapParams.amountSpecified));
                uint256 swapFeeAmount = inputAmount1.mulDivUp(fee, SWAP_FEE_BASE - fee);
                inputAmount1 += swapFeeAmount;
            }

            if (
                (inputAmount0 > outputAmount1 && outputAmount0 > inputAmount1)
                    || (inputAmount0 < outputAmount1 && outputAmount0 < inputAmount1)
            ) {
                // not valid roundtrip swap since the swap amounts don't chain together
                return;
            }

            console2.log("inputAmount0", inputAmount0);
            console2.log("outputAmount0", outputAmount0);
            console2.log("inputAmount1", inputAmount1);
            console2.log("outputAmount1", outputAmount1);
            console2.log("currentTick", currentTick);
            console2.log("updatedTick", updatedTick);
            console2.log("updatedSqrtPriceX96", updatedSqrtPriceX96);
            console2.log("updatedTick0", updatedTick0);
            console2.log("updatedSqrtPriceX960", updatedSqrtPriceX960);

            if (amountSpecified < 0) {
                assertWithMsg(inputAmount0 >= outputAmount1, "Round trips swaps are profitable");
            } else {
                assertWithMsg(outputAmount0 <= inputAmount1, "Round trips swaps are profitable");
            }
        } catch Panic(uint256) /*errorCode*/ {
            // This is executed in case of a panic,
            // i.e. a serious error like division by zero
            // or overflow. The error code can be used
            // to determine the kind of error.
            //assert(false);
            return;
        } catch (bytes memory reason) {
            emit LogBytes(reason);
            return;
        }
    }

    function test_compare_swap_with_reverse_swap_with_exactIn_vs_exactOut(
        int24 tickSpacing,
        uint64 balance0,
        uint64 balance1,
        int64 amountSpecified,
        uint160 sqrtPriceLimit,
        int24 currentTick,
        uint24 fee,
        bool zeroForOne,
        bytes8 ldfSeed
    ) public {
        (tickSpacing, amountSpecified, currentTick) = _processInputs(tickSpacing, amountSpecified, currentTick);

        if (amountSpecified == 0) return;

        fee = uint24(clampBetween(fee, MIN_SWAP_FEE, SWAP_FEE_BASE));

        // Set up LDF
        _setUpLDF(ldfSeed, tickSpacing);

        // Initialize parameters before swapinng
        (BunniSwapMath.BunniComputeSwapInput memory input1, IdleBalance idleBalance) =
            _compute_swap(tickSpacing, balance0, balance1, amountSpecified, sqrtPriceLimit, currentTick, zeroForOne);

        // avoid edge case where the active balance of the output token is 0
        // or if the output token's balance is less than requested in an exact output swap
        if (
            (zeroForOne && input1.currentActiveBalance1 == 0) || (!zeroForOne && input1.currentActiveBalance0 == 0)
                || input1.totalLiquidity == 0
                || (
                    amountSpecified > 0
                        && uint64(amountSpecified) > (zeroForOne ? input1.currentActiveBalance1 : input1.currentActiveBalance0)
                )
        ) {
            return;
        }

        if (input1.totalLiquidity < 1e3) return;

        try this.swap(input1) returns (
            uint160 updatedSqrtPriceX96, int24 updatedTick, uint256 inputAmount0, uint256 outputAmount0
        ) {
            // apply fee
            bool exactIn = amountSpecified < 0;
            if (exactIn) {
                inputAmount0 = FixedPointMathLib.max(inputAmount0, uint64(-amountSpecified));
                uint256 swapFeeAmount = outputAmount0.mulDivUp(fee, SWAP_FEE_BASE);
                outputAmount0 -= swapFeeAmount;
            } else {
                outputAmount0 = FixedPointMathLib.min(outputAmount0, uint64(amountSpecified));
                uint256 swapFeeAmount = inputAmount0.mulDivUp(fee, SWAP_FEE_BASE - fee);
                inputAmount0 += swapFeeAmount;
            }

            if (inputAmount0 != uint64(inputAmount0) || outputAmount0 != uint64(outputAmount0)) return;

            BunniSwapMath.BunniComputeSwapInput memory input2 = _compute_swap(
                tickSpacing,
                uint64(balance0 + inputAmount0),
                uint64(balance1 - outputAmount0),
                -amountSpecified,
                input1.sqrtPriceX96, // sqrtPriceLimit
                updatedTick,
                !zeroForOne,
                updatedSqrtPriceX96,
                idleBalance
            );
            // avoid edge case where the active balance of the output token is 0
            // or if the output token's balance is less than requested in an exact output swap
            if (
                (zeroForOne && input2.currentActiveBalance1 == 0) || (!zeroForOne && input2.currentActiveBalance0 == 0)
                    || input2.totalLiquidity == 0
                    || (
                        amountSpecified > 0
                            && uint64(amountSpecified)
                                > (zeroForOne ? input2.currentActiveBalance1 : input2.currentActiveBalance0)
                    )
            ) {
                return;
            }
            input2.swapParams.amountSpecified = exactIn ? int256(inputAmount0) : -int256(outputAmount0);

            if (input2.swapParams.amountSpecified == 0) return;

            (uint160 updatedSqrtPriceX960, int24 updatedTick0, uint256 inputAmount1, uint256 outputAmount1) =
                this.swap(input2);

            // apply fee
            if (!exactIn) {
                inputAmount1 = FixedPointMathLib.max(inputAmount1, uint256(-input2.swapParams.amountSpecified));
                uint256 swapFeeAmount = outputAmount1.mulDivUp(fee, SWAP_FEE_BASE);
                outputAmount1 -= swapFeeAmount;
            } else {
                outputAmount1 = FixedPointMathLib.min(outputAmount1, uint256(input2.swapParams.amountSpecified));
                uint256 swapFeeAmount = inputAmount1.mulDivUp(fee, SWAP_FEE_BASE - fee);
                inputAmount1 += swapFeeAmount;
            }

            if (
                (inputAmount0 > outputAmount1 && outputAmount0 > inputAmount1)
                    || (inputAmount0 < outputAmount1 && outputAmount0 < inputAmount1)
            ) {
                // not valid roundtrip swap since the swap amounts don't chain together
                return;
            }

            console2.log("inputAmount0", inputAmount0);
            console2.log("outputAmount0", outputAmount0);
            console2.log("inputAmount1", inputAmount1);
            console2.log("outputAmount1", outputAmount1);
            console2.log("currentTick", currentTick);
            console2.log("updatedTick", updatedTick);
            console2.log("updatedSqrtPriceX96", updatedSqrtPriceX96);
            console2.log("updatedTick0", updatedTick0);
            console2.log("updatedSqrtPriceX960", updatedSqrtPriceX960);

            if (exactIn) {
                assertWithMsg(outputAmount0 <= inputAmount1 + MAX_PROFIT, "Round trips swaps are profitable");
            } else {
                assertWithMsg(inputAmount0 + MAX_PROFIT >= outputAmount1, "Round trips swaps are profitable");
            }
        } catch Panic(uint256) /*errorCode*/ {
            // This is executed in case of a panic,
            // i.e. a serious error like division by zero
            // or overflow. The error code can be used
            // to determine the kind of error.
            //assert(false);
            return;
        } catch (bytes memory reason) {
            emit LogBytes(reason);
            return;
        }
    }

    // Invariant: Users should not be able to gain any tokens through round trip swaps.
    // Issue: TOB-BUNNI-16
    // This test fails only if the swap fee is zero.
    function test_compare_swap_with_reverse_swap_with_zeroForOne_vs_oneForZero_noSqrtPriceLimit(
        int24 tickSpacing,
        uint64 balance0,
        uint64 balance1,
        int64 amountSpecified,
        int24 currentTick,
        uint24 fee,
        bool zeroForOne,
        bytes8 ldfSeed
    ) public {
        (tickSpacing, amountSpecified, currentTick) = _processInputs(tickSpacing, amountSpecified, currentTick);

        if (amountSpecified == 0) return;

        fee = uint24(clampBetween(fee, MIN_SWAP_FEE, SWAP_FEE_BASE));

        console2.log("fee", fee);

        // Set up LDF
        _setUpLDF(ldfSeed, tickSpacing);

        // Initialize parameters before swapinng
        (BunniSwapMath.BunniComputeSwapInput memory input1, IdleBalance idleBalance) = _compute_swap(
            tickSpacing,
            balance0,
            balance1,
            amountSpecified,
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            currentTick,
            zeroForOne
        );

        // avoid edge case where the active balance of the output token is 0
        // or if the output token's balance is less than requested in an exact output swap
        if (
            (zeroForOne && input1.currentActiveBalance1 == 0) || (!zeroForOne && input1.currentActiveBalance0 == 0)
                || input1.totalLiquidity == 0
                || (
                    amountSpecified > 0
                        && uint64(amountSpecified) > (zeroForOne ? input1.currentActiveBalance1 : input1.currentActiveBalance0)
                )
        ) {
            return;
        }

        if (input1.totalLiquidity < 1e3) return;

        try this.swap(input1) returns (
            uint160 updatedSqrtPriceX96, int24 updatedTick, uint256 inputAmount0, uint256 outputAmount0
        ) {
            // apply fee
            bool exactIn = amountSpecified < 0;
            if (exactIn) {
                inputAmount0 = FixedPointMathLib.max(inputAmount0, uint64(-amountSpecified));
                uint256 swapFeeAmount = outputAmount0.mulDivUp(fee, SWAP_FEE_BASE);
                outputAmount0 -= swapFeeAmount;
            } else {
                outputAmount0 = FixedPointMathLib.min(outputAmount0, uint64(amountSpecified));
                uint256 swapFeeAmount = inputAmount0.mulDivUp(fee, SWAP_FEE_BASE - fee);
                inputAmount0 += swapFeeAmount;
            }

            if (inputAmount0 != uint64(inputAmount0) || outputAmount0 != uint64(outputAmount0)) return;

            BunniSwapMath.BunniComputeSwapInput memory input2 = _compute_swap(
                tickSpacing,
                uint64(balance0 + inputAmount0),
                uint64(balance1 - outputAmount0),
                -amountSpecified,
                !zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1, // sqrtPriceLimit
                updatedTick,
                !zeroForOne,
                updatedSqrtPriceX96,
                idleBalance
            );
            // avoid edge case where the active balance of the output token is 0
            // or if the output token's balance is less than requested in an exact output swap
            if (
                (zeroForOne && input2.currentActiveBalance1 == 0) || (!zeroForOne && input2.currentActiveBalance0 == 0)
                    || input2.totalLiquidity == 0
                    || (
                        amountSpecified > 0
                            && uint64(amountSpecified)
                                > (zeroForOne ? input2.currentActiveBalance1 : input2.currentActiveBalance0)
                    )
            ) {
                return;
            }
            input2.swapParams.amountSpecified = exactIn ? -int256(outputAmount0) : int256(inputAmount0);

            if (input2.swapParams.amountSpecified == 0) return;

            (uint160 updatedSqrtPriceX960, int24 updatedTick0, uint256 inputAmount1, uint256 outputAmount1) =
                this.swap(input2);

            // apply fee
            if (exactIn) {
                inputAmount1 = FixedPointMathLib.max(inputAmount1, uint256(-input2.swapParams.amountSpecified));
                uint256 swapFeeAmount = outputAmount1.mulDivUp(fee, SWAP_FEE_BASE);
                outputAmount1 -= swapFeeAmount;
            } else {
                outputAmount1 = FixedPointMathLib.min(outputAmount1, uint256(input2.swapParams.amountSpecified));
                uint256 swapFeeAmount = inputAmount1.mulDivUp(fee, SWAP_FEE_BASE - fee);
                inputAmount1 += swapFeeAmount;
            }

            if (
                (inputAmount0 > outputAmount1 && outputAmount0 > inputAmount1)
                    || (inputAmount0 < outputAmount1 && outputAmount0 < inputAmount1)
            ) {
                // not valid roundtrip swap since the swap amounts don't chain together
                return;
            }

            console2.log("inputAmount0", inputAmount0);
            console2.log("outputAmount0", outputAmount0);
            console2.log("inputAmount1", inputAmount1);
            console2.log("outputAmount1", outputAmount1);
            console2.log("currentTick", currentTick);
            console2.log("updatedTick", updatedTick);
            console2.log("updatedSqrtPriceX96", updatedSqrtPriceX96);
            console2.log("updatedTick0", updatedTick0);
            console2.log("updatedSqrtPriceX960", updatedSqrtPriceX960);

            if (amountSpecified < 0) {
                assertWithMsg(inputAmount0 + MAX_PROFIT >= outputAmount1, "Round trips swaps are profitable");
            } else {
                assertWithMsg(outputAmount0 <= inputAmount1 + MAX_PROFIT, "Round trips swaps are profitable");
            }
        } catch Panic(uint256) /*errorCode*/ {
            // This is executed in case of a panic,
            // i.e. a serious error like division by zero
            // or overflow. The error code can be used
            // to determine the kind of error.
            //assert(false);
            return;
        } catch (bytes memory reason) {
            emit LogBytes(reason);
            return;
        }
    }

    function test_compare_swap_with_reverse_swap_with_exactIn_vs_exactOut_noSqrtPriceLimit(
        int24 tickSpacing,
        uint64 balance0,
        uint64 balance1,
        int64 amountSpecified,
        int24 currentTick,
        uint24 fee,
        bool zeroForOne,
        bytes8 ldfSeed
    ) public {
        (tickSpacing, amountSpecified, currentTick) = _processInputs(tickSpacing, amountSpecified, currentTick);

        if (amountSpecified == 0) return;

        fee = uint24(clampBetween(fee, MIN_SWAP_FEE, SWAP_FEE_BASE));

        // Set up LDF
        _setUpLDF(ldfSeed, tickSpacing);

        // Initialize parameters before swapinng
        (BunniSwapMath.BunniComputeSwapInput memory input1, IdleBalance idleBalance) = _compute_swap(
            tickSpacing,
            balance0,
            balance1,
            amountSpecified,
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            currentTick,
            zeroForOne
        );

        // avoid edge case where the active balance of the output token is 0
        // or if the output token's balance is less than requested in an exact output swap
        if (
            (zeroForOne && input1.currentActiveBalance1 == 0) || (!zeroForOne && input1.currentActiveBalance0 == 0)
                || input1.totalLiquidity == 0
                || (
                    amountSpecified > 0
                        && uint64(amountSpecified) > (zeroForOne ? input1.currentActiveBalance1 : input1.currentActiveBalance0)
                )
        ) {
            return;
        }

        if (input1.totalLiquidity < 1e3) return;

        try this.swap(input1) returns (
            uint160 updatedSqrtPriceX96, int24 updatedTick, uint256 inputAmount0, uint256 outputAmount0
        ) {
            // apply fee
            bool exactIn = amountSpecified < 0;
            if (exactIn) {
                inputAmount0 = FixedPointMathLib.max(inputAmount0, uint64(-amountSpecified));
                uint256 swapFeeAmount = outputAmount0.mulDivUp(fee, SWAP_FEE_BASE);
                outputAmount0 -= swapFeeAmount;
            } else {
                outputAmount0 = FixedPointMathLib.min(outputAmount0, uint64(amountSpecified));
                uint256 swapFeeAmount = inputAmount0.mulDivUp(fee, SWAP_FEE_BASE - fee);
                inputAmount0 += swapFeeAmount;
            }

            if (inputAmount0 != uint64(inputAmount0) || outputAmount0 != uint64(outputAmount0)) return;

            BunniSwapMath.BunniComputeSwapInput memory input2 = _compute_swap(
                tickSpacing,
                uint64(balance0 + inputAmount0),
                uint64(balance1 - outputAmount0),
                -amountSpecified,
                !zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1, // sqrtPriceLimit
                updatedTick,
                !zeroForOne,
                updatedSqrtPriceX96,
                idleBalance
            );
            // avoid edge case where the active balance of the output token is 0
            // or if the output token's balance is less than requested in an exact output swap
            if (
                (zeroForOne && input2.currentActiveBalance1 == 0) || (!zeroForOne && input2.currentActiveBalance0 == 0)
                    || input2.totalLiquidity == 0
                    || (
                        amountSpecified > 0
                            && uint64(amountSpecified)
                                > (zeroForOne ? input2.currentActiveBalance1 : input2.currentActiveBalance0)
                    )
            ) {
                return;
            }
            input2.swapParams.amountSpecified = exactIn ? int256(inputAmount0) : -int256(outputAmount0);

            if (input2.swapParams.amountSpecified == 0) return;

            (uint160 updatedSqrtPriceX960, int24 updatedTick0, uint256 inputAmount1, uint256 outputAmount1) =
                this.swap(input2);

            // apply fee
            if (!exactIn) {
                inputAmount1 = FixedPointMathLib.max(inputAmount1, uint256(-input2.swapParams.amountSpecified));
                uint256 swapFeeAmount = outputAmount1.mulDivUp(fee, SWAP_FEE_BASE);
                outputAmount1 -= swapFeeAmount;
            } else {
                outputAmount1 = FixedPointMathLib.min(outputAmount1, uint256(input2.swapParams.amountSpecified));
                uint256 swapFeeAmount = inputAmount1.mulDivUp(fee, SWAP_FEE_BASE - fee);
                inputAmount1 += swapFeeAmount;
            }

            if (
                (inputAmount0 > outputAmount1 && outputAmount0 > inputAmount1)
                    || (inputAmount0 < outputAmount1 && outputAmount0 < inputAmount1)
            ) {
                // not valid roundtrip swap since the swap amounts don't chain together
                return;
            }

            console2.log("inputAmount0", inputAmount0);
            console2.log("outputAmount0", outputAmount0);
            console2.log("inputAmount1", inputAmount1);
            console2.log("outputAmount1", outputAmount1);
            console2.log("currentTick", currentTick);
            console2.log("updatedTick", updatedTick);
            console2.log("updatedSqrtPriceX96", updatedSqrtPriceX96);
            console2.log("updatedTick0", updatedTick0);
            console2.log("updatedSqrtPriceX960", updatedSqrtPriceX960);

            if (exactIn) {
                assertWithMsg(outputAmount0 <= inputAmount1 + MAX_PROFIT, "Round trips swaps are profitable");
            } else {
                assertWithMsg(inputAmount0 + MAX_PROFIT >= outputAmount1, "Round trips swaps are profitable");
            }
        } catch Panic(uint256) /*errorCode*/ {
            // This is executed in case of a panic,
            // i.e. a serious error like division by zero
            // or overflow. The error code can be used
            // to determine the kind of error.
            //assert(false);
            return;
        } catch (bytes memory reason) {
            emit LogBytes(reason);
            return;
        }
    }

    // Internal helper function
    function swap(BunniSwapMath.BunniComputeSwapInput calldata input)
        public
        view
        returns (uint160 updatedSqrtPriceX96, int24 updatedTick, uint256 inputAmount0, uint256 outputAmount0)
    {
        require(msg.sender == address(this));
        (updatedSqrtPriceX96, updatedTick, inputAmount0, outputAmount0) = BunniSwapMath.computeSwap(input);
    }

    // Invariant: computeSwap in BunniSwapMath should output a valid sqrtPrice of the pool after the swap.
    function test_sqrtPrice_after_the_swap_is_valid(
        int24 tickSpacing,
        uint64 balance0,
        uint64 balance1,
        int64 amountSpecified,
        uint160 sqrtPriceLimit,
        int24 currentTick,
        bool zeroForOne,
        bytes8 ldfSeed
    ) public {
        (tickSpacing, amountSpecified, currentTick) = _processInputs(tickSpacing, amountSpecified, currentTick);

        if (amountSpecified == 0) return;

        // Set up LDF
        _setUpLDF(ldfSeed, tickSpacing);

        // Initialize parameters before swapinng
        (BunniSwapMath.BunniComputeSwapInput memory input1,) =
            _compute_swap(tickSpacing, balance0, balance1, amountSpecified, sqrtPriceLimit, currentTick, zeroForOne);

        // avoid edge case where the active balance of the output token is 0
        // or if the output token's balance is less than requested in an exact output swap
        if (
            (zeroForOne && input1.currentActiveBalance1 == 0) || (!zeroForOne && input1.currentActiveBalance0 == 0)
                || input1.totalLiquidity == 0
                || (
                    amountSpecified > 0
                        && uint64(amountSpecified) > (zeroForOne ? input1.currentActiveBalance1 : input1.currentActiveBalance0)
                )
        ) {
            return;
        }

        try this.swap(input1) returns (
            uint160 updatedSqrtPriceX96, int24 updatedTick, uint256 inputAmount0, uint256 outputAmount0
        ) {
            if (outputAmount0 == 0 || inputAmount0 == 0) return;
            assertWithMsg(
                updatedSqrtPriceX96 >= MIN_SQRT_PRICE && updatedSqrtPriceX96 <= MAX_SQRT_PRICE,
                "sqrtPrice is outside the Limit"
            );
        } catch Panic(uint256) /*errorCode*/ {
            // This is executed in case of a panic,
            // i.e. a serious error like division by zero
            // or overflow. The error code can be used
            // to determine the kind of error.
            //assert(false);
            return;
        } catch (bytes memory reason) {
            emit LogBytes(reason);
            return;
        }
    }

    // Invariant: computeSwap in BunniSwapMath should not raise any panics
    //            during a swap on a valid pool state.
    // Issue: TOB-BUNNI-18
    function test_swap_panics(
        int24 tickSpacing,
        uint64 balance0,
        uint64 balance1,
        int64 amountSpecified,
        uint160 sqrtPriceLimit,
        int24 currentTick,
        bool zeroForOne,
        bytes8 ldfSeed
    ) public {
        (tickSpacing, amountSpecified, currentTick) = _processInputs(tickSpacing, amountSpecified, currentTick);

        if (amountSpecified == 0 || FixedPointMathLib.abs(amountSpecified) < 1e5) return;

        // Set up LDF
        _setUpLDF(ldfSeed, tickSpacing);

        // Initialize parameters before swapinng
        (BunniSwapMath.BunniComputeSwapInput memory input1,) =
            _compute_swap(tickSpacing, balance0, balance1, amountSpecified, sqrtPriceLimit, currentTick, zeroForOne);

        // avoid edge case where the active balance of the output token is 0
        // or if the output token's balance is less than requested in an exact output swap
        if (
            (zeroForOne && input1.currentActiveBalance1 == 0) || (!zeroForOne && input1.currentActiveBalance0 == 0)
                || input1.totalLiquidity == 0
                || (
                    amountSpecified > 0
                        && uint64(amountSpecified) > (zeroForOne ? input1.currentActiveBalance1 : input1.currentActiveBalance0)
                )
        ) {
            return;
        }

        try this.swap(input1) returns (
            uint160 updatedSqrtPriceX96, int24 updatedTick, uint256 inputAmount0, uint256 outputAmount0
        ) {} catch Panic(uint256) {
            // This is executed in case of a panic,
            // i.e. a serious error like division by zero
            // or overflow. The error code can be used
            // to determine the kind of error.
            assertWithMsg(false, "panic");
        } catch (bytes memory reason) {
            emit LogBytes(reason);
            return;
        }
    }

    function _processInputs(int24 tickSpacing, int64 amountSpecified, int24 currentTick)
        internal
        returns (int24 tickSpacing_, int64 amountSpecified_, int24 currentTick_)
    {
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
        tickSpacing = int24(clampBetween(tickSpacing, MIN_TICK_SPACING, MAX_TICK_SPACING));
        currentTick = int24(clampBetween(currentTick, minUsableTick, maxUsableTick));
        amountSpecified = int64(clampBetween(amountSpecified, type(int64).min, type(int64).max));

        return (tickSpacing, amountSpecified, currentTick);
    }

    function _compute_idle_balance(
        int24 tickSpacing,
        uint64 balance0,
        uint64 balance1,
        int24 currentTick,
        uint160 sqrtPriceX96
    ) internal returns (IdleBalance idleBalance) {
        uint256 totalLiquidity;
        uint256 totalDensity0X96;
        uint256 totalDensity1X96;
        uint256 liquidityDensityOfRoundedTickX96;
        uint256 currentActiveBalance0;
        uint256 currentActiveBalance1;
        {
            PoolKey memory key;
            key.tickSpacing = tickSpacing;
            (
                totalLiquidity,
                totalDensity0X96,
                totalDensity1X96,
                liquidityDensityOfRoundedTickX96,
                currentActiveBalance0,
                currentActiveBalance1,
                ,
            ) = queryLDF({
                key: key,
                sqrtPriceX96: sqrtPriceX96,
                tick: currentTick,
                arithmeticMeanTick: int24(0),
                ldf: ldf,
                ldfParams: ldfParams,
                ldfState: LDF_STATE,
                balance0: balance0,
                balance1: balance1,
                idleBalance: IdleBalanceLibrary.ZERO
            });
        }

        (uint256 extraBalance0, uint256 extraBalance1) = (
            balance0 > currentActiveBalance0 ? balance0 - currentActiveBalance0 : 0,
            balance1 > currentActiveBalance1 ? balance1 - currentActiveBalance1 : 0
        );
        console2.log("extraBalance0", extraBalance0);
        console2.log("extraBalance1", extraBalance1);
        (uint256 extraBalanceProportion0, uint256 extraBalanceProportion1) =
            (balance0 == 0 ? 0 : extraBalance0.divWad(balance0), balance1 == 0 ? 0 : extraBalance1.divWad(balance1));
        console2.log("extraBalanceProportion0", extraBalanceProportion0);
        console2.log("extraBalanceProportion1", extraBalanceProportion1);
        bool isToken0 = extraBalanceProportion0 >= extraBalanceProportion1;
        return (isToken0 ? extraBalance0 : extraBalance1).toIdleBalance(isToken0);
    }

    function _compute_swap(
        int24 tickSpacing,
        uint64 balance0,
        uint64 balance1,
        int64 amountSpecified,
        uint160 sqrtPriceLimitX96,
        int24 currentTick,
        bool zeroForOne
    ) internal returns (BunniSwapMath.BunniComputeSwapInput memory input, IdleBalance idleBalance) {
        // compute sqrtPriceX96 and idleBalance
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(currentTick);
        idleBalance = _compute_idle_balance(tickSpacing, balance0, balance1, currentTick, sqrtPriceX96);

        input = _compute_swap(
            tickSpacing,
            balance0,
            balance1,
            amountSpecified,
            sqrtPriceLimitX96,
            currentTick,
            zeroForOne,
            sqrtPriceX96,
            idleBalance
        );
    }

    // Helper function to initialize the parameters for the swap
    function _compute_swap(
        int24 tickSpacing,
        uint64 balance0,
        uint64 balance1,
        int64 amountSpecified,
        uint160 sqrtPriceLimitX96,
        int24 currentTick,
        bool zeroForOne,
        uint160 sqrtPriceX96,
        IdleBalance idleBalance
    ) internal returns (BunniSwapMath.BunniComputeSwapInput memory input) {
        // set up pool key
        PoolKey memory key;
        key.tickSpacing = tickSpacing;

        require(ldf.isValidParams(key, 0, ldfParams, LDFType.STATIC), "invalid LDF params");

        // set up BunniComputeSwapInput
        input.key = key;
        input.sqrtPriceX96 = sqrtPriceX96;
        input.currentTick = currentTick;
        input.liquidityDensityFunction = ldf;
        input.arithmeticMeanTick = int24(0);
        input.ldfParams = ldfParams;
        input.ldfState = LDF_STATE;

        // initialize swap params
        input.swapParams.amountSpecified = amountSpecified;
        input.swapParams.sqrtPriceLimitX96 = zeroForOne
            ? uint160(clampBetween(sqrtPriceLimitX96, MIN_SQRT_PRICE, sqrtPriceX96 - 1))
            : uint160(clampBetween(sqrtPriceLimitX96, sqrtPriceX96 + 1, MAX_SQRT_PRICE));
        input.swapParams.zeroForOne = zeroForOne;

        // query the LDF to get total liquidity and token densities
        (
            uint256 totalLiquidity,
            ,
            ,
            uint256 liquidityDensityOfRoundedTickX96,
            uint256 currentActiveBalance0,
            uint256 currentActiveBalance1,
            ,
        ) = queryLDF({
            key: key,
            sqrtPriceX96: input.sqrtPriceX96,
            tick: input.currentTick,
            arithmeticMeanTick: input.arithmeticMeanTick,
            ldf: ldf,
            ldfParams: ldfParams,
            ldfState: LDF_STATE,
            balance0: balance0,
            balance1: balance1,
            idleBalance: idleBalance
        });

        input.totalLiquidity = totalLiquidity;
        input.currentActiveBalance0 = currentActiveBalance0;
        input.currentActiveBalance1 = currentActiveBalance1;
        input.liquidityDensityOfRoundedTickX96 = liquidityDensityOfRoundedTickX96;

        return input;
    }

    function _setUpLDF(bytes8 ldfSeed, int24 tickSpacing) internal {
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));

        uint8 ldfIdx = uint8(clampBetween(_rng(ldfSeed, 0), 0, NUM_LDFS - 1));
        if (ldfIdx == 0) {
            console2.log("UniformDistribution");
            ldf =
                ILiquidityDensityFunction(address(new UniformDistribution(address(this), address(this), address(this))));
            int24 tickLower = roundTickSingle(
                int24(clampBetween(int256(_rng(ldfSeed, 1)), minUsableTick, maxUsableTick)), tickSpacing
            );
            int24 tickUpper = roundTickSingle(
                int24(clampBetween(int256(_rng(ldfSeed, 2)), tickLower + tickSpacing, maxUsableTick)), tickSpacing
            );
            ldfParams = bytes32(abi.encodePacked(ShiftMode.STATIC, tickLower, tickUpper));

            console2.log("tickLower", tickLower);
            console2.log("tickUpper", tickUpper);
        } else if (ldfIdx == 1) {
            console2.log("GeometricDistribution");
            ldf = ILiquidityDensityFunction(
                address(new GeometricDistribution(address(this), address(this), address(this)))
            );
            int24 minTick = roundTickSingle(
                int24(clampBetween(int256(_rng(ldfSeed, 1)), minUsableTick, maxUsableTick - 2 * tickSpacing)),
                tickSpacing
            );
            int16 length = int16(clampBetween(int256(_rng(ldfSeed, 2)), 1, maxUsableTick / tickSpacing - 2));
            uint32 alpha = uint32(clampBetween(_rng(ldfSeed, 3), MIN_ALPHA, MAX_ALPHA));
            ldfParams = bytes32(abi.encodePacked(ShiftMode.STATIC, minTick, length, alpha));

            console2.log("minTick", minTick);
            console2.log("length", length);
            console2.log("alpha", alpha);
        } else if (ldfIdx == 2) {
            console2.log("DoubleGeometricDistribution");
            ldf = ILiquidityDensityFunction(
                address(new DoubleGeometricDistribution(address(this), address(this), address(this)))
            );
            int24 minTick = roundTickSingle(
                int24(clampBetween(int256(_rng(ldfSeed, 1)), minUsableTick, maxUsableTick - 2 * tickSpacing)),
                tickSpacing
            );
            int16 length0 = int16(clampBetween(int256(_rng(ldfSeed, 2)), 1, maxUsableTick / tickSpacing - 2));
            uint32 alpha0 = uint32(clampBetween(_rng(ldfSeed, 3), MIN_ALPHA, MAX_ALPHA));
            int16 length1 = int16(clampBetween(int256(_rng(ldfSeed, 4)), 1, maxUsableTick / tickSpacing - 2));
            uint32 alpha1 = uint32(clampBetween(_rng(ldfSeed, 5), MIN_ALPHA, MAX_ALPHA));
            uint32 weight0 = uint32(clampBetween(_rng(ldfSeed, 6), uint256(1), uint256(1e6)));
            uint32 weight1 = uint32(clampBetween(_rng(ldfSeed, 7), uint256(1), uint256(1e6)));
            ldfParams =
                bytes32(abi.encodePacked(ShiftMode.STATIC, minTick, length0, alpha0, weight0, length1, alpha1, weight1));

            console2.log("minTick", minTick);
            console2.log("length0", length0);
            console2.log("alpha0", alpha0);
            console2.log("weight0", weight0);
            console2.log("length1", length1);
            console2.log("alpha1", alpha1);
            console2.log("weight1", weight1);
        } else if (ldfIdx == 3) {
            console2.log("CarpetedGeometricDistribution");
            ldf = ILiquidityDensityFunction(
                address(new CarpetedGeometricDistribution(address(this), address(this), address(this)))
            );
            int24 minTick = roundTickSingle(
                int24(clampBetween(int256(_rng(ldfSeed, 1)), minUsableTick, maxUsableTick - 2 * tickSpacing)),
                tickSpacing
            );
            int16 length = int16(clampBetween(int256(_rng(ldfSeed, 2)), 1, maxUsableTick / tickSpacing - 2));
            uint32 alpha = uint32(clampBetween(_rng(ldfSeed, 3), MIN_ALPHA, MAX_ALPHA));
            uint32 weightCarpet = uint32(clampBetween(_rng(ldfSeed, 4), 1, type(uint32).max));
            ldfParams = bytes32(abi.encodePacked(ShiftMode.STATIC, minTick, length, alpha, weightCarpet));

            console2.log("minTick", minTick);
            console2.log("length", length);
            console2.log("alpha", alpha);
            console2.log("weightCarpet", weightCarpet);
        } else if (ldfIdx == 4) {
            console2.log("CarpetedDoubleGeometricDistribution");
            ldf = ILiquidityDensityFunction(
                address(new CarpetedDoubleGeometricDistribution(address(this), address(this), address(this)))
            );
            int24 minTick = roundTickSingle(
                int24(clampBetween(int256(_rng(ldfSeed, 1)), minUsableTick, maxUsableTick - 2 * tickSpacing)),
                tickSpacing
            );
            int16 length0 = int16(clampBetween(int256(_rng(ldfSeed, 2)), 1, maxUsableTick / tickSpacing - 2));
            uint32 alpha0 = uint32(clampBetween(_rng(ldfSeed, 3), MIN_ALPHA, MAX_ALPHA));
            int16 length1 = int16(clampBetween(int256(_rng(ldfSeed, 4)), 1, maxUsableTick / tickSpacing - 2));
            uint32 alpha1 = uint32(clampBetween(_rng(ldfSeed, 5), MIN_ALPHA, MAX_ALPHA));
            uint32 weight0 = uint32(clampBetween(_rng(ldfSeed, 6), uint256(1), uint256(1e6)));
            uint32 weight1 = uint32(clampBetween(_rng(ldfSeed, 7), uint256(1), uint256(1e6)));
            uint32 weightCarpet = uint32(clampBetween(_rng(ldfSeed, 8), 1, type(uint32).max));
            ldfParams = bytes32(
                abi.encodePacked(
                    ShiftMode.STATIC, minTick, length0, alpha0, weight0, length1, alpha1, weight1, weightCarpet
                )
            );

            console2.log("minTick", minTick);
            console2.log("length0", length0);
            console2.log("alpha0", alpha0);
            console2.log("weight0", weight0);
            console2.log("length1", length1);
            console2.log("alpha1", alpha1);
            console2.log("weight1", weight1);
            console2.log("weightCarpet", weightCarpet);
        }
    }

    function _rng(bytes8 seed, uint8 id) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(seed, id)));
    }
}
