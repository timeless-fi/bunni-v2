// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import {PoolKey} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import "./ShiftMode.sol";
import {LibDoubleGeometricDistribution} from "./LibDoubleGeometricDistribution.sol";
import {ILiquidityDensityFunction} from "../interfaces/ILiquidityDensityFunction.sol";

contract DoubleGeometricDistribution is ILiquidityDensityFunction {
    uint32 internal constant INITIALIZED_STATE = 1 << 24;

    function query(
        PoolKey calldata key,
        int24 roundedTick,
        int24 twapTick,
        int24, /* spotPriceTick */
        bool useTwap,
        bytes32 ldfParams,
        bytes32 ldfState
    )
        external
        pure
        override
        returns (
            uint256 liquidityDensityX96_,
            uint256 cumulativeAmount0DensityX96,
            uint256 cumulativeAmount1DensityX96,
            bytes32 newLdfState,
            bool shouldSurge
        )
    {
        (
            int24 minTick,
            int24 length0,
            int24 length1,
            uint256 alpha0X96,
            uint256 alpha1X96,
            uint256 weight0,
            uint256 weight1,
            ShiftMode shiftMode
        ) = LibDoubleGeometricDistribution.decodeParams(twapTick, key.tickSpacing, useTwap, ldfParams);
        (bool initialized, int24 lastMinTick) = _decodeState(ldfState);
        if (initialized) {
            minTick = enforceShiftMode(minTick, lastMinTick, shiftMode);
            shouldSurge = minTick != lastMinTick;
        }

        (liquidityDensityX96_, cumulativeAmount0DensityX96, cumulativeAmount1DensityX96) =
        LibDoubleGeometricDistribution.query(
            roundedTick, key.tickSpacing, minTick, length0, length1, alpha0X96, alpha1X96, weight0, weight1
        );
        newLdfState = _encodeState(minTick);
    }

    function computeSwap(
        PoolKey calldata key,
        uint256 inverseCumulativeAmountInput,
        uint256 totalLiquidity,
        bool zeroForOne,
        bool exactIn,
        int24 twapTick,
        int24, /* spotPriceTick */
        bool useTwap,
        bytes32 ldfParams,
        bytes32 ldfState
    )
        external
        pure
        override
        returns (bool success, int24 roundedTick, uint256 cumulativeAmount, uint128 swapLiquidity)
    {
        (
            int24 minTick,
            int24 length0,
            int24 length1,
            uint256 alpha0X96,
            uint256 alpha1X96,
            uint256 weight0,
            uint256 weight1,
            ShiftMode shiftMode
        ) = LibDoubleGeometricDistribution.decodeParams(twapTick, key.tickSpacing, useTwap, ldfParams);
        (bool initialized, int24 lastMinTick) = _decodeState(ldfState);
        if (initialized) {
            minTick = enforceShiftMode(minTick, lastMinTick, shiftMode);
        }

        return LibDoubleGeometricDistribution.computeSwap(
            inverseCumulativeAmountInput,
            totalLiquidity,
            zeroForOne,
            exactIn,
            key.tickSpacing,
            minTick,
            length0,
            length1,
            alpha0X96,
            alpha1X96,
            weight0,
            weight1
        );
    }

    function isValidParams(int24 tickSpacing, uint24 twapSecondsAgo, bytes32 ldfParams)
        external
        pure
        override
        returns (bool)
    {
        return LibDoubleGeometricDistribution.isValidParams(tickSpacing, twapSecondsAgo, ldfParams);
    }

    function cumulativeAmount0(
        PoolKey calldata key,
        int24 roundedTick,
        uint256 totalLiquidity,
        int24 twapTick,
        int24, /* spotPriceTick */
        bool useTwap,
        bytes32 ldfParams,
        bytes32 ldfState
    ) external pure override returns (uint256) {
        (
            int24 minTick,
            int24 length0,
            int24 length1,
            uint256 alpha0X96,
            uint256 alpha1X96,
            uint256 weight0,
            uint256 weight1,
            ShiftMode shiftMode
        ) = LibDoubleGeometricDistribution.decodeParams(twapTick, key.tickSpacing, useTwap, ldfParams);
        (bool initialized, int24 lastMinTick) = _decodeState(ldfState);
        if (initialized) {
            minTick = enforceShiftMode(minTick, lastMinTick, shiftMode);
        }

        return LibDoubleGeometricDistribution.cumulativeAmount0(
            roundedTick,
            totalLiquidity,
            key.tickSpacing,
            minTick,
            length0,
            length1,
            alpha0X96,
            alpha1X96,
            weight0,
            weight1
        );
    }

    function cumulativeAmount1(
        PoolKey calldata key,
        int24 roundedTick,
        uint256 totalLiquidity,
        int24 twapTick,
        int24, /* spotPriceTick */
        bool useTwap,
        bytes32 ldfParams,
        bytes32 ldfState
    ) external pure override returns (uint256) {
        (
            int24 minTick,
            int24 length0,
            int24 length1,
            uint256 alpha0X96,
            uint256 alpha1X96,
            uint256 weight0,
            uint256 weight1,
            ShiftMode shiftMode
        ) = LibDoubleGeometricDistribution.decodeParams(twapTick, key.tickSpacing, useTwap, ldfParams);
        (bool initialized, int24 lastMinTick) = _decodeState(ldfState);
        if (initialized) {
            minTick = enforceShiftMode(minTick, lastMinTick, shiftMode);
        }

        return LibDoubleGeometricDistribution.cumulativeAmount1(
            roundedTick,
            totalLiquidity,
            key.tickSpacing,
            minTick,
            length0,
            length1,
            alpha0X96,
            alpha1X96,
            weight0,
            weight1
        );
    }

    function _decodeState(bytes32 ldfState) internal pure returns (bool initialized, int24 lastMinTick) {
        // | initialized - 1 byte | lastMinTick - 3 bytes |
        initialized = uint8(bytes1(ldfState)) == 1;
        lastMinTick = int24(uint24(bytes3(ldfState << 8)));
    }

    function _encodeState(int24 lastMinTick) internal pure returns (bytes32 ldfState) {
        // | initialized - 1 byte | lastMinTick - 3 bytes |
        ldfState = bytes32(bytes4(INITIALIZED_STATE + uint32(uint24(lastMinTick))));
    }
}
