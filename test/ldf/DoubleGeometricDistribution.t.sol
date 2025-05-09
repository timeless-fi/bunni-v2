// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import {console2} from "forge-std/console2.sol";

import "./LiquidityDensityFunctionTest.sol";
import {LDFType} from "../../src/types/LDFType.sol";
import "../../src/ldf/DoubleGeometricDistribution.sol";

contract DoubleGeometricDistributionTest is LiquidityDensityFunctionTest {
    uint256 internal constant MIN_ALPHA = 1e3;
    uint256 internal constant MAX_ALPHA = 10e8;
    uint256 internal constant INVCUM_MIN_MAX_CUM_AMOUNT = 1e6;

    function _setUpLDF() internal override {
        ldf = ILiquidityDensityFunction(
            address(new DoubleGeometricDistribution(address(this), address(this), address(this)))
        );
    }

    function test_liquidityDensity_sumUpToOne(
        int24 tickSpacing,
        int24 minTick,
        int24 length0,
        uint256 alpha0,
        int24 length1,
        uint256 alpha1,
        uint32 weight0,
        uint32 weight1
    ) external virtual {
        tickSpacing = int24(bound(tickSpacing, MIN_TICK_SPACING, MAX_TICK_SPACING));
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));

        weight0 = uint32(bound(weight0, 1, 1e6));
        weight1 = uint32(bound(weight1, 1, 1e6));

        alpha1 = bound(alpha1, MIN_ALPHA, MAX_ALPHA);
        vm.assume(alpha1 != 1e8); // 1e8 is a special case that causes overflow
        minTick = roundTickSingle(int24(bound(minTick, minUsableTick, maxUsableTick - 3 * tickSpacing)), tickSpacing);
        length1 = int24(bound(length1, 1, (maxUsableTick - minTick) / tickSpacing - 2));

        alpha0 = bound(alpha0, MIN_ALPHA, MAX_ALPHA);
        vm.assume(alpha0 != 1e8); // 1e8 is a special case that causes overflow
        length0 = int24(bound(length0, 1, (maxUsableTick - (minTick + length1 * tickSpacing)) / tickSpacing - 1));

        console2.log("tickSpacing", tickSpacing);
        console2.log("minTick", minTick);
        console2.log("alpha0", alpha0);
        console2.log("length0", length0);
        console2.log("alpha1", alpha1);
        console2.log("length1", length1);
        console2.log("weight0", weight0);
        console2.log("weight1", weight1);

        PoolKey memory key;
        key.tickSpacing = tickSpacing;
        bytes32 ldfParams = bytes32(
            abi.encodePacked(
                ShiftMode.STATIC,
                minTick,
                int16(length0),
                uint32(alpha0),
                weight0,
                int16(length1),
                uint32(alpha1),
                weight1
            )
        );
        vm.assume(ldf.isValidParams(key, 0, ldfParams, LDFType.STATIC));
        _test_liquidityDensity_sumUpToOne(tickSpacing, ldfParams);
    }

    function test_query_cumulativeAmounts(
        int24 currentTick,
        int24 tickSpacing,
        int24 minTick,
        int24 length0,
        uint256 alpha0,
        int24 length1,
        uint256 alpha1,
        uint32 weight0,
        uint32 weight1
    ) external virtual {
        tickSpacing = int24(bound(tickSpacing, MIN_TICK_SPACING, MAX_TICK_SPACING));
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));

        weight0 = uint32(bound(weight0, 1, 1e6));
        weight1 = uint32(bound(weight1, 1, 1e6));

        alpha1 = bound(alpha1, MIN_ALPHA, MAX_ALPHA);
        vm.assume(alpha1 != 1e8); // 1e8 is a special case that causes overflow
        minTick = roundTickSingle(int24(bound(minTick, minUsableTick, maxUsableTick - 2 * tickSpacing)), tickSpacing);
        length1 = int24(bound(length1, 1, (maxUsableTick - minTick) / tickSpacing - 1));

        alpha0 = bound(alpha0, MIN_ALPHA, MAX_ALPHA);
        vm.assume(alpha0 != 1e8); // 1e8 is a special case that causes overflow
        vm.assume((maxUsableTick - (minTick + length1 * tickSpacing)) / tickSpacing - 1 >= 1);
        length0 = int24(bound(length0, 1, (maxUsableTick - (minTick + length1 * tickSpacing)) / tickSpacing - 1));

        console2.log("tickSpacing", tickSpacing);
        console2.log("minTick", minTick);
        console2.log("alpha0", alpha0);
        console2.log("length0", length0);
        console2.log("alpha1", alpha1);
        console2.log("length1", length1);
        console2.log("weight0", weight0);
        console2.log("weight1", weight1);

        PoolKey memory key;
        key.tickSpacing = tickSpacing;
        bytes32 ldfParams = bytes32(
            abi.encodePacked(
                ShiftMode.STATIC,
                minTick,
                int16(length0),
                uint32(alpha0),
                weight0,
                int16(length1),
                uint32(alpha1),
                weight1
            )
        );
        vm.assume(ldf.isValidParams(key, 0, ldfParams, LDFType.STATIC));

        currentTick = int24(bound(currentTick, minUsableTick, maxUsableTick));
        _test_query_cumulativeAmounts(currentTick, tickSpacing, ldfParams);
    }

    function test_inverseCumulativeAmount0(
        uint256 liquidity,
        uint256 cumulativeAmount0,
        int24 tickSpacing,
        int24 minTick,
        int24 length0,
        uint256 alpha0,
        int24 length1,
        uint256 alpha1,
        uint32 weight0,
        uint32 weight1
    ) external virtual {
        liquidity = bound(liquidity, 1e18, 1e36);
        tickSpacing = int24(bound(tickSpacing, MIN_TICK_SPACING, MAX_TICK_SPACING));
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));

        weight0 = uint32(bound(weight0, 1, 1e6));
        weight1 = uint32(bound(weight1, 1, 1e6));

        alpha1 = bound(alpha1, MIN_ALPHA, MAX_ALPHA);
        vm.assume(alpha1 != 1e8); // 1e8 is a special case that causes overflow
        minTick = roundTickSingle(int24(bound(minTick, minUsableTick, maxUsableTick - 2 * tickSpacing)), tickSpacing);
        length1 = int24(bound(length1, 1, (maxUsableTick - minTick) / tickSpacing - 1));

        alpha0 = bound(alpha0, MIN_ALPHA, MAX_ALPHA);
        vm.assume(alpha0 != 1e8); // 1e8 is a special case that causes overflow
        vm.assume((maxUsableTick - (minTick + length1 * tickSpacing)) / tickSpacing - 1 >= 1);
        length0 = int24(bound(length0, 1, (maxUsableTick - (minTick + length1 * tickSpacing)) / tickSpacing - 1));

        PoolKey memory key;
        key.tickSpacing = tickSpacing;
        bytes32 ldfParams = bytes32(
            abi.encodePacked(
                ShiftMode.STATIC,
                minTick,
                int16(length0),
                uint32(alpha0),
                weight0,
                int16(length1),
                uint32(alpha1),
                weight1
            )
        );
        vm.assume(ldf.isValidParams(key, 0, ldfParams, LDFType.STATIC));

        uint256 alpha0X96 = (alpha0 << 96) / 1e8;
        uint256 alpha1X96 = (alpha1 << 96) / 1e8;
        uint256 maxCumulativeAmount0 = LibDoubleGeometricDistribution.cumulativeAmount0(
            minUsableTick, liquidity, tickSpacing, minTick, length0, length1, alpha0X96, alpha1X96, weight0, weight1
        );
        vm.assume(maxCumulativeAmount0 > INVCUM_MIN_MAX_CUM_AMOUNT); // ignore distributions where there's basically 0 tokens
        cumulativeAmount0 = bound(cumulativeAmount0, 0, maxCumulativeAmount0);

        console2.log("cumulativeAmount0", cumulativeAmount0);
        console2.log("maxCumulativeAmount0", maxCumulativeAmount0);
        console2.log("minTick", minTick);
        console2.log("alpha0", alpha0);
        console2.log("length0", length0);
        console2.log("alpha1", alpha1);
        console2.log("length1", length1);
        console2.log("weight0", weight0);
        console2.log("weight1", weight1);

        (bool success, int24 resultRoundedTick) = LibDoubleGeometricDistribution.inverseCumulativeAmount0(
            cumulativeAmount0, liquidity, tickSpacing, minTick, length0, length1, alpha0X96, alpha1X96, weight0, weight1
        );
        if (!success) return;
        console2.log("resultRoundedTick", resultRoundedTick);

        uint256 resultCumulativeAmount0 = LibDoubleGeometricDistribution.cumulativeAmount0(
            resultRoundedTick, liquidity, tickSpacing, minTick, length0, length1, alpha0X96, alpha1X96, weight0, weight1
        );

        assertGe(resultCumulativeAmount0, cumulativeAmount0, "resultCumulativeAmount0 < cumulativeAmount0");

        if (resultRoundedTick < minTick + length0 * tickSpacing + length1 * tickSpacing && cumulativeAmount0 > 1e3) {
            uint256 nextCumulativeAmount0 = LibDoubleGeometricDistribution.cumulativeAmount0(
                resultRoundedTick + tickSpacing,
                liquidity,
                tickSpacing,
                minTick,
                length0,
                length1,
                alpha0X96,
                alpha1X96,
                weight0,
                weight1
            );
            assertLt(nextCumulativeAmount0, cumulativeAmount0, "nextCumulativeAmount0 >= cumulativeAmount0");
        }
    }

    function test_inverseCumulativeAmount1(
        uint256 liquidity,
        uint256 cumulativeAmount1,
        int24 tickSpacing,
        int24 minTick,
        int24 length0,
        uint256 alpha0,
        int24 length1,
        uint256 alpha1,
        uint32 weight0,
        uint32 weight1
    ) external virtual {
        liquidity = bound(liquidity, 1e18, 1e36);
        tickSpacing = int24(bound(tickSpacing, MIN_TICK_SPACING, MAX_TICK_SPACING));
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));

        weight0 = uint32(bound(weight0, 1, 1e6));
        weight1 = uint32(bound(weight1, 1, 1e6));

        alpha1 = bound(alpha1, MIN_ALPHA, MAX_ALPHA);
        vm.assume(alpha1 != 1e8); // 1e8 is a special case that causes overflow
        minTick = roundTickSingle(int24(bound(minTick, minUsableTick, maxUsableTick - 2 * tickSpacing)), tickSpacing);
        length1 = int24(bound(length1, 1, (maxUsableTick - minTick) / tickSpacing - 1));

        alpha0 = bound(alpha0, MIN_ALPHA, MAX_ALPHA);
        vm.assume(alpha0 != 1e8); // 1e8 is a special case that causes overflow
        vm.assume((maxUsableTick - (minTick + length1 * tickSpacing)) / tickSpacing - 1 >= 1);
        length0 = int24(bound(length0, 1, (maxUsableTick - (minTick + length1 * tickSpacing)) / tickSpacing - 1));

        PoolKey memory key;
        key.tickSpacing = tickSpacing;
        bytes32 ldfParams = bytes32(
            abi.encodePacked(
                ShiftMode.STATIC,
                minTick,
                int16(length0),
                uint32(alpha0),
                weight0,
                int16(length1),
                uint32(alpha1),
                weight1
            )
        );
        vm.assume(ldf.isValidParams(key, 0, ldfParams, LDFType.STATIC));

        uint256 alpha0X96 = (alpha0 << 96) / 1e8;
        uint256 alpha1X96 = (alpha1 << 96) / 1e8;
        uint256 maxCumulativeAmount1 = LibDoubleGeometricDistribution.cumulativeAmount1(
            maxUsableTick, liquidity, tickSpacing, minTick, length0, length1, alpha0X96, alpha1X96, weight0, weight1
        );
        vm.assume(maxCumulativeAmount1 > INVCUM_MIN_MAX_CUM_AMOUNT); // ignore distributions where there's basically 0 tokens
        cumulativeAmount1 = bound(cumulativeAmount1, 0, maxCumulativeAmount1);

        console2.log("cumulativeAmount1", cumulativeAmount1);
        console2.log("maxCumulativeAmount1", maxCumulativeAmount1);
        console2.log("minTick", minTick);
        console2.log("alpha0", alpha0);
        console2.log("length0", length0);
        console2.log("alpha1", alpha1);
        console2.log("length1", length1);
        console2.log("weight0", weight0);
        console2.log("weight1", weight1);

        (bool success, int24 resultRoundedTick) = LibDoubleGeometricDistribution.inverseCumulativeAmount1(
            cumulativeAmount1, liquidity, tickSpacing, minTick, length0, length1, alpha0X96, alpha1X96, weight0, weight1
        );
        if (!success) return;
        console2.log("resultRoundedTick", resultRoundedTick);

        uint256 resultCumulativeAmount1 = LibDoubleGeometricDistribution.cumulativeAmount1(
            resultRoundedTick, liquidity, tickSpacing, minTick, length0, length1, alpha0X96, alpha1X96, weight0, weight1
        );

        assertGe(resultCumulativeAmount1, cumulativeAmount1, "resultCumulativeAmount1 < cumulativeAmount1");

        if (resultRoundedTick > minTick && cumulativeAmount1 > 2) {
            uint256 nextCumulativeAmount1 = LibDoubleGeometricDistribution.cumulativeAmount1(
                resultRoundedTick - tickSpacing,
                liquidity,
                tickSpacing,
                minTick,
                length0,
                length1,
                alpha0X96,
                alpha1X96,
                weight0,
                weight1
            );
            assertLt(nextCumulativeAmount1, cumulativeAmount1, "nextCumulativeAmount1 >= cumulativeAmount1");
        }
    }

    function test_boundary_static_invalidWhenOutOfBounds(int24 tickSpacing) external view {
        tickSpacing = int24(bound(tickSpacing, MIN_TICK_SPACING, MAX_TICK_SPACING));
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
        uint32 alpha0 = 0.9e8;
        uint32 alpha1 = 1.1e8;
        uint32 weight0 = 1;
        uint32 weight1 = 1;
        PoolKey memory key;
        key.tickSpacing = tickSpacing;

        // invalid when minTick < minUsableTick
        (int24 minTick, int24 length0, int24 length1) = (minUsableTick - tickSpacing, 1, 1);
        bytes32 ldfParams = bytes32(
            abi.encodePacked(
                ShiftMode.STATIC,
                minTick,
                int16(length0),
                uint32(alpha0),
                weight0,
                int16(length1),
                uint32(alpha1),
                weight1
            )
        );
        assertFalse(ldf.isValidParams(key, 0, ldfParams, LDFType.STATIC));

        // invalid when maxTick > maxUsableTick
        (minTick, length0, length1) = (maxUsableTick - tickSpacing, 1, 1);
        ldfParams = bytes32(
            abi.encodePacked(
                ShiftMode.STATIC,
                minTick,
                int16(length0),
                uint32(alpha0),
                weight0,
                int16(length1),
                uint32(alpha1),
                weight1
            )
        );
        assertFalse(ldf.isValidParams(key, 0, ldfParams, LDFType.STATIC));

        // valid test
        (minTick, length0, length1) = (0, 1, 1);
        ldfParams = bytes32(
            abi.encodePacked(
                ShiftMode.STATIC,
                minTick,
                int16(length0),
                uint32(alpha0),
                weight0,
                int16(length1),
                uint32(alpha1),
                weight1
            )
        );
        assertTrue(ldf.isValidParams(key, 0, ldfParams, LDFType.STATIC));
    }

    function test_boundary_dynamic_boundedWhenDecoding(int24 tickSpacing) external view {
        tickSpacing = int24(bound(tickSpacing, MIN_TICK_SPACING, MAX_TICK_SPACING));
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
        uint32 alpha0 = 0.9e8;
        uint32 alpha1 = 1.1e8;
        uint32 weight0 = 1;
        uint32 weight1 = 1;
        ShiftMode shiftMode = ShiftMode.RIGHT;
        PoolKey memory key;
        key.tickSpacing = tickSpacing;

        // bounded when minTick < minUsableTick
        (int24 offset, int24 length0, int24 length1) = (minUsableTick - tickSpacing, 1, 1);
        bytes32 ldfParams = bytes32(
            abi.encodePacked(
                shiftMode, offset, int16(length0), uint32(alpha0), weight0, int16(length1), uint32(alpha1), weight1
            )
        );
        assertTrue(ldf.isValidParams(key, 1, ldfParams, LDFType.DYNAMIC_AND_STATEFUL), "invalid params 0");
        (int24 minTick,,,,,,, ShiftMode decodedShiftMode) =
            LibDoubleGeometricDistribution.decodeParams(0, tickSpacing, ldfParams);
        assertEq(minTick, minUsableTick, "minTick incorrect");
        assertTrue(shiftMode == decodedShiftMode, "shiftMode incorrect");

        // bounded when maxTick > maxUsableTick
        (offset, length0, length1) = (maxUsableTick - tickSpacing, 1, 1);
        ldfParams = ldfParams = bytes32(
            abi.encodePacked(
                shiftMode, offset, int16(length0), uint32(alpha0), weight0, int16(length1), uint32(alpha1), weight1
            )
        );
        assertTrue(ldf.isValidParams(key, 1, ldfParams, LDFType.DYNAMIC_AND_STATEFUL), "invalid params 1");
        (minTick,,,,,,, decodedShiftMode) = LibDoubleGeometricDistribution.decodeParams(0, tickSpacing, ldfParams);
        assertEq(minTick + (length0 + length1) * tickSpacing, maxUsableTick, "maxTick incorrect");
        assertTrue(shiftMode == decodedShiftMode, "shiftMode incorrect");
    }
}
