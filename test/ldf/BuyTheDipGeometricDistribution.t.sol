// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {LDFType} from "../../src/types/LDFType.sol";
import {ShiftMode} from "../../src/ldf/ShiftMode.sol";
import {ILiquidityDensityFunction} from "../../src/interfaces/ILiquidityDensityFunction.sol";
import {BuyTheDipGeometricDistribution} from "../../src/ldf/BuyTheDipGeometricDistribution.sol";

contract BuyTheDipGeometricDistributionTest is Test {
    ILiquidityDensityFunction internal ldf;
    int24 internal constant TICK_SPACING = 1;
    int24 internal constant MAX_TICK_SPACING = type(int16).max;
    int24 internal constant MIN_TICK_SPACING = 1;

    function setUp() public {
        ldf = new BuyTheDipGeometricDistribution(address(this), address(this), address(this));
    }

    function test_morphToAltAlphaAndBack() external view {
        PoolKey memory key;
        key.tickSpacing = TICK_SPACING;
        int24 minTick = -9 * TICK_SPACING;
        int16 length = 10;
        uint32 alpha = 1.2e8;
        uint32 altAlpha = 0.8e8;
        int24 altThreshold = -2 * TICK_SPACING;
        bool altThresholdDirection = true;
        bytes32 ldfParams = bytes32(
            abi.encodePacked(ShiftMode.STATIC, minTick, length, alpha, altAlpha, altThreshold, altThresholdDirection)
        );
        assertTrue(ldf.isValidParams(key, 1 minutes, ldfParams, LDFType.DYNAMIC_AND_STATEFUL), "LDF params are invalid");

        // make first query
        (uint256 liquidityDensityX96,,, bytes32 ldfState, bool shouldSurge) = ldf.query({
            key: key,
            roundedTick: 0,
            twapTick: 0,
            spotPriceTick: 0,
            ldfParams: ldfParams,
            ldfState: bytes32(0)
        });
        assertFalse(shouldSurge, "initial query surges");

        // make second query where the TWAP reaches the threshold
        uint256 newLiquidityDensityX96;
        (newLiquidityDensityX96,,, ldfState, shouldSurge) = ldf.query({
            key: key,
            roundedTick: 0,
            twapTick: altThreshold,
            spotPriceTick: 0,
            ldfParams: ldfParams,
            ldfState: ldfState
        });
        assertTrue(shouldSurge, "second query does not surge");
        assertNotEq(liquidityDensityX96, newLiquidityDensityX96, "second liquidity density did not change");

        // make third query where the TWAP stays below the threshold
        liquidityDensityX96 = newLiquidityDensityX96;
        (newLiquidityDensityX96,,, ldfState, shouldSurge) = ldf.query({
            key: key,
            roundedTick: 0,
            twapTick: altThreshold - TICK_SPACING,
            spotPriceTick: 0,
            ldfParams: ldfParams,
            ldfState: ldfState
        });
        assertFalse(shouldSurge, "third query surges");
        assertEq(liquidityDensityX96, newLiquidityDensityX96, "third liquidity density changed");

        // make fourth query where the TWAP goes back above the threshold
        liquidityDensityX96 = newLiquidityDensityX96;
        (newLiquidityDensityX96,,, ldfState, shouldSurge) = ldf.query({
            key: key,
            roundedTick: 0,
            twapTick: altThreshold + TICK_SPACING,
            spotPriceTick: 0,
            ldfParams: ldfParams,
            ldfState: ldfState
        });
        assertTrue(shouldSurge, "fourth query does not surge");
        assertNotEq(liquidityDensityX96, newLiquidityDensityX96, "fourth liquidity density did not change");
    }

    function test_isValidParams(int24 tickSpacing) external view {
        tickSpacing = int24(bound(tickSpacing, MIN_TICK_SPACING, MAX_TICK_SPACING));
        PoolKey memory key;
        key.tickSpacing = tickSpacing;
        int24 minTick = -9 * tickSpacing;
        int16 length = 10;
        uint32 alpha = 1.2e8;
        uint32 altAlpha = 0.8e8;
        int24 altThreshold = -2 * tickSpacing;
        bool altThresholdDirection = true;
        bytes32 ldfParams = bytes32(
            abi.encodePacked(ShiftMode.STATIC, minTick, length, alpha, altAlpha, altThreshold, altThresholdDirection)
        );
        assertTrue(ldf.isValidParams(key, 1 minutes, ldfParams, LDFType.DYNAMIC_AND_STATEFUL), "LDF params are invalid");

        // validity conditions:
        // - need TWAP to be enabled to trigger the alt alpha switch
        // - both LDFs are valid
        // - threshold makes sense i.e. both LDFs can be used at some point
        // - alpha and altAlpha are on different sides of 1
        // - does not exceed minUsableTick or maxUsableTick

        // invalid TWAP
        assertFalse(ldf.isValidParams(key, 0, ldfParams, LDFType.DYNAMIC_AND_STATEFUL), "allow 0 TWAP window");

        // invalid LDFs
        ldfParams = bytes32(
            abi.encodePacked(ShiftMode.STATIC, minTick, length, alpha, uint32(1e8), altThreshold, altThresholdDirection)
        );
        assertFalse(
            ldf.isValidParams(key, 1 minutes, ldfParams, LDFType.DYNAMIC_AND_STATEFUL), "allow invalid alt alpha"
        );
        ldfParams = bytes32(
            abi.encodePacked(
                ShiftMode.STATIC, minTick, length, uint32(1e8), altAlpha, altThreshold, altThresholdDirection
            )
        );
        assertFalse(ldf.isValidParams(key, 1 minutes, ldfParams, LDFType.DYNAMIC_AND_STATEFUL), "allow invalid alpha");

        // invalid threshold
        ldfParams = bytes32(
            abi.encodePacked(ShiftMode.STATIC, minTick, length, alpha, altAlpha, minTick, altThresholdDirection)
        );
        assertFalse(
            ldf.isValidParams(key, 1 minutes, ldfParams, LDFType.DYNAMIC_AND_STATEFUL), "allow invalid threshold"
        );
        ldfParams = bytes32(
            abi.encodePacked(
                ShiftMode.STATIC,
                minTick,
                length,
                alpha,
                altAlpha,
                minTick + length * key.tickSpacing,
                altThresholdDirection
            )
        );
        assertFalse(
            ldf.isValidParams(key, 1 minutes, ldfParams, LDFType.DYNAMIC_AND_STATEFUL), "allow invalid threshold"
        );

        // invalid alpha and altAlpha combo
        ldfParams = bytes32(
            abi.encodePacked(
                ShiftMode.STATIC, minTick, length, uint32(1.2e8), uint32(1.5e8), altThreshold, altThresholdDirection
            )
        );
        assertFalse(
            ldf.isValidParams(key, 1 minutes, ldfParams, LDFType.DYNAMIC_AND_STATEFUL),
            "allow invalid alpha and alt alpha combo"
        );

        // exceeds min/max usable ticks
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(key.tickSpacing), TickMath.maxUsableTick(key.tickSpacing));
        ldfParams = bytes32(
            abi.encodePacked(
                ShiftMode.STATIC,
                minUsableTick - key.tickSpacing,
                length,
                alpha,
                altAlpha,
                altThreshold,
                altThresholdDirection
            )
        );
        assertFalse(
            ldf.isValidParams(key, 1 minutes, ldfParams, LDFType.DYNAMIC_AND_STATEFUL), "allow below min usable tick"
        );
        ldfParams = bytes32(
            abi.encodePacked(
                ShiftMode.STATIC,
                maxUsableTick - length * key.tickSpacing + key.tickSpacing,
                length,
                alpha,
                altAlpha,
                altThreshold,
                altThresholdDirection
            )
        );
        assertFalse(
            ldf.isValidParams(key, 1 minutes, ldfParams, LDFType.DYNAMIC_AND_STATEFUL), "allow above max usable tick"
        );

        // invalid ldfType
        ldfParams = bytes32(
            abi.encodePacked(ShiftMode.STATIC, minTick, length, alpha, altAlpha, altThreshold, altThresholdDirection)
        );
        assertFalse(ldf.isValidParams(key, 1 minutes, ldfParams, LDFType.STATIC), "allow invalid ldfType");
    }
}
