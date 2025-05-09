// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0;
pragma abicoder v2;

import {PoolKey} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {LDFType} from "../types/LDFType.sol";

/// @title ILiquidityDensityFunction
/// @author zefram.eth
/// @notice Interface for liquidity density functions (LDFs) that dictate how liquidity is distributed over a pool's rounded ticks (each with `tickSpacing` ticks).
/// Each rounded tick is identified by its leftmost tick, which is a multiple of `tickSpacing`. The liquidity density of all rounded ticks should add up to 1, similar to probability density functions (PDFs).
/// Also contains functions for efficiently computing the cumulative amount of tokens in a consecutive range of rounded ticks, as well as their inverse functions. These are essential for computing swaps.
/// Enables arbitrary liquidity shapes, shifting liquidity across ticks, and switching from one liquidity shape to another.
interface ILiquidityDensityFunction {
    /// @notice Queries the liquidity density function for the given pool and rounded tick.
    /// Returns the density of the rounded tick, cumulative token densities at adjacent ticks, and state relevant info.
    /// @param key The key of the Uniswap v4 pool
    /// @param roundedTick The rounded tick to query
    /// @param twapTick The TWAP tick. Is 0 if `twapSecondsAgo` is 0. It's up to `isValidParams` to ensure `twapSecondsAgo != 0` if the LDF uses the TWAP.
    /// @param spotPriceTick The spot price tick.
    /// @param ldfParams The parameters for the liquidity density function
    /// @param ldfState The current state of the liquidity density function
    /// @return liquidityDensityX96 The density of the rounded tick, scaled by Q96
    /// @return cumulativeAmount0DensityX96 The cumulative token0 density in rounded ticks [roundedTick + tickSpacing, maxUsableTick], scaled by Q96
    /// @return cumulativeAmount1DensityX96 The cumulative token1 density in rounded ticks [minUsableTick, roundedTick - tickSpacing], scaled by Q96
    /// @return newLdfState The new state of the liquidity density function
    /// @return shouldSurge Whether the pool should surge. Usually corresponds to whether the LDF has shifted / changed shape.
    function query(
        PoolKey calldata key,
        int24 roundedTick,
        int24 twapTick,
        int24 spotPriceTick,
        bytes32 ldfParams,
        bytes32 ldfState
    )
        external
        view
        returns (
            uint256 liquidityDensityX96,
            uint256 cumulativeAmount0DensityX96,
            uint256 cumulativeAmount1DensityX96,
            bytes32 newLdfState,
            bool shouldSurge
        );

    /// @notice Aggregates LDF queries used during a swap.
    /// @dev A Bunni swap uses the inverseCumulativeAmount function to compute the rounded tick for which the cumulativeAmount is the closest to `inverseCumulativeAmountInput`
    /// and <= `inverseCumulativeAmountInput`. This rounded tick is the starting point for swapping the remaining tokens, which is done via Uniswap math (not done in this function though).
    /// @param key The key of the Uniswap v4 pool
    /// @param inverseCumulativeAmountInput The input to the inverseCumulativeAmount function
    /// @param totalLiquidity The total liquidity in the pool
    /// @param zeroForOne Whether the input token is token0
    /// @param exactIn Whether it's an exact input swap or an exact output swap
    /// @param twapTick The TWAP tick. Is 0 if `twapSecondsAgo` is 0. It's up to `isValidParams` to ensure `twapSecondsAgo != 0` if the LDF uses the TWAP.
    /// @param spotPriceTick The spot price tick.
    /// @param ldfParams The parameters for the liquidity density function
    /// @param ldfState The current state of the liquidity density function
    /// @return success Whether the swap computation was successful
    /// @return roundedTick The rounded tick to start the remainder swap from
    /// @return cumulativeAmount0_ The cumulative amount of token0 to the right of the starting tick of the Uniswap swap
    /// @return cumulativeAmount1_ The cumulative amount of token1 to the left of the starting tick of the Uniswap swap
    /// @return swapLiquidity The liquidity used for the remainder swap
    function computeSwap(
        PoolKey calldata key,
        uint256 inverseCumulativeAmountInput,
        uint256 totalLiquidity,
        bool zeroForOne,
        bool exactIn,
        int24 twapTick,
        int24 spotPriceTick,
        bytes32 ldfParams,
        bytes32 ldfState
    )
        external
        view
        returns (
            bool success,
            int24 roundedTick,
            uint256 cumulativeAmount0_,
            uint256 cumulativeAmount1_,
            uint256 swapLiquidity
        );

    /// @notice Computes the cumulative amount of token0 in the rounded ticks [roundedTick, maxUsableTick].
    /// @param key The key of the Uniswap v4 pool
    /// @param roundedTick The rounded tick to query
    /// @param totalLiquidity The total liquidity in the pool
    /// @param twapTick The TWAP tick. Is 0 if `twapSecondsAgo` is 0. It's up to `isValidParams` to ensure `twapSecondsAgo != 0` if the LDF uses the TWAP.
    /// @param spotPriceTick The spot price tick.
    /// @param ldfParams The parameters for the liquidity density function
    /// @param ldfState The current state of the liquidity density function
    /// @return The cumulative amount of token0 in the rounded ticks [roundedTick, maxUsableTick]
    function cumulativeAmount0(
        PoolKey calldata key,
        int24 roundedTick,
        uint256 totalLiquidity,
        int24 twapTick,
        int24 spotPriceTick,
        bytes32 ldfParams,
        bytes32 ldfState
    ) external view returns (uint256);

    /// @notice Computes the cumulative amount of token1 in the rounded ticks [minUsableTick, roundedTick].
    /// @param key The key of the Uniswap v4 pool
    /// @param roundedTick The rounded tick to query
    /// @param totalLiquidity The total liquidity in the pool
    /// @param twapTick The TWAP tick. Is 0 if `twapSecondsAgo` is 0. It's up to `isValidParams` to ensure `twapSecondsAgo != 0` if the LDF uses the TWAP.
    /// @param spotPriceTick The spot price tick.
    /// @param ldfParams The parameters for the liquidity density function
    /// @param ldfState The current state of the liquidity density function
    /// @return The cumulative amount of token1 in the rounded ticks [minUsableTick, roundedTick]
    function cumulativeAmount1(
        PoolKey calldata key,
        int24 roundedTick,
        uint256 totalLiquidity,
        int24 twapTick,
        int24 spotPriceTick,
        bytes32 ldfParams,
        bytes32 ldfState
    ) external view returns (uint256);

    /// @notice Checks if the given LDF parameters are valid.
    /// @param key The key of the Uniswap v4 pool
    /// @param twapSecondsAgo The time window for the TWAP
    /// @param ldfParams The parameters for the liquidity density function
    /// @param ldfType The type of LDF, see LDFType.sol for details.
    /// @return Whether the parameters are valid
    function isValidParams(PoolKey calldata key, uint24 twapSecondsAgo, bytes32 ldfParams, LDFType ldfType)
        external
        view
        returns (bool);
}
