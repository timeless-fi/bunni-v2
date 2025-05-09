// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import {console2} from "forge-std/console2.sol";

import "./LiquidityDensityFunctionTest.sol";
import {LDFType} from "../../src/types/LDFType.sol";
import "../../src/ldf/CarpetedDoubleGeometricDistribution.sol";
import "../../src/ldf/LibCarpetedDoubleGeometricDistribution.sol";

contract CarpetedDoubleGeometricDistributionTest is LiquidityDensityFunctionTest {
    uint256 internal constant MIN_ALPHA = 1e3;
    uint256 internal constant MAX_ALPHA = 12e8;
    uint256 internal constant INVCUM_MIN_MAX_CUM_AMOUNT = 1e6;
    uint8 internal constant QUERY_SCALE_SHIFT = 4;

    function _setUpLDF() internal override {
        ldf = ILiquidityDensityFunction(
            address(new CarpetedDoubleGeometricDistribution(address(this), address(this), address(this)))
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
        uint32 weight1,
        uint256 weightCarpet
    ) external virtual {
        tickSpacing = int24(bound(tickSpacing, MIN_TICK_SPACING, MAX_TICK_SPACING));
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
        PoolKey memory key;
        key.tickSpacing = tickSpacing;

        weight0 = uint32(bound(weight0, 1, 1e6));
        weight1 = uint32(bound(weight1, 1, 1e6));

        alpha1 = bound(alpha1, MIN_ALPHA, MAX_ALPHA);
        vm.assume(alpha1 != 1e8); // 1e8 is a special case that causes overflow
        minTick = roundTickSingle(int24(bound(minTick, minUsableTick, maxUsableTick - 3 * tickSpacing)), tickSpacing);
        length1 = int24(bound(length1, 1, (maxUsableTick - minTick) / tickSpacing - 2));

        alpha0 = bound(alpha0, MIN_ALPHA, MAX_ALPHA);
        vm.assume(alpha0 != 1e8); // 1e8 is a special case that causes overflow
        length0 = int24(bound(length0, 1, (maxUsableTick - (minTick + length1 * tickSpacing)) / tickSpacing - 1));

        weightCarpet = bound(weightCarpet, 1, type(uint32).max);

        console2.log("tickSpacing", tickSpacing);
        console2.log("minTick", minTick);
        console2.log("alpha0", alpha0);
        console2.log("length0", length0);
        console2.log("alpha1", alpha1);
        console2.log("length1", length1);
        console2.log("weight0", weight0);
        console2.log("weight1", weight1);

        bytes32 ldfParams = bytes32(
            abi.encodePacked(
                ShiftMode.STATIC,
                minTick,
                int16(length0),
                uint32(alpha0),
                weight0,
                int16(length1),
                uint32(alpha1),
                weight1,
                uint32(weightCarpet)
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
        uint32 weight1,
        uint256 weightCarpet
    ) external virtual {
        tickSpacing = int24(bound(tickSpacing, MIN_TICK_SPACING, MAX_TICK_SPACING));
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
        PoolKey memory key;
        key.tickSpacing = tickSpacing;

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

        weightCarpet = bound(weightCarpet, 1, type(uint32).max);

        console2.log("tickSpacing", tickSpacing);
        console2.log("minTick", minTick);
        console2.log("alpha0", alpha0);
        console2.log("length0", length0);
        console2.log("alpha1", alpha1);
        console2.log("length1", length1);
        console2.log("weight0", weight0);
        console2.log("weight1", weight1);

        bytes32 ldfParams = bytes32(
            abi.encodePacked(
                ShiftMode.STATIC,
                minTick,
                int16(length0),
                uint32(alpha0),
                weight0,
                int16(length1),
                uint32(alpha1),
                weight1,
                uint32(weightCarpet)
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
        uint32 weight1,
        uint256 weightCarpet
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

        weightCarpet = bound(weightCarpet, 1, type(uint32).max);

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
                weight1,
                uint32(weightCarpet)
            )
        );
        vm.assume(ldf.isValidParams(key, 0, ldfParams, LDFType.STATIC));

        LibCarpetedDoubleGeometricDistribution.Params memory params =
            LibCarpetedDoubleGeometricDistribution.decodeParams(minTick, tickSpacing, ldfParams);
        uint256 maxCumulativeAmount0 =
            LibCarpetedDoubleGeometricDistribution.cumulativeAmount0(minUsableTick, liquidity, tickSpacing, params);
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
        console2.log("weightCarpet", weightCarpet);

        (bool success, int24 resultRoundedTick) = LibCarpetedDoubleGeometricDistribution.inverseCumulativeAmount0(
            cumulativeAmount0, liquidity, tickSpacing, params
        );
        if (!success) return;
        console2.log("resultRoundedTick", resultRoundedTick);

        uint256 resultCumulativeAmount0 =
            LibCarpetedDoubleGeometricDistribution.cumulativeAmount0(resultRoundedTick, liquidity, tickSpacing, params);

        assertGe(resultCumulativeAmount0, cumulativeAmount0, "resultCumulativeAmount0 < cumulativeAmount0");

        if (resultRoundedTick < minTick + length0 * tickSpacing + length1 * tickSpacing && cumulativeAmount0 > 1e3) {
            uint256 nextCumulativeAmount0 = LibCarpetedDoubleGeometricDistribution.cumulativeAmount0(
                resultRoundedTick + tickSpacing, liquidity, tickSpacing, params
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
        uint32 weight1,
        uint256 weightCarpet
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

        weightCarpet = bound(weightCarpet, 1, type(uint32).max);

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
                weight1,
                uint32(weightCarpet)
            )
        );
        vm.assume(ldf.isValidParams(key, 0, ldfParams, LDFType.STATIC));

        LibCarpetedDoubleGeometricDistribution.Params memory params =
            LibCarpetedDoubleGeometricDistribution.decodeParams(minTick, tickSpacing, ldfParams);
        uint256 maxCumulativeAmount1 =
            LibCarpetedDoubleGeometricDistribution.cumulativeAmount1(maxUsableTick, liquidity, tickSpacing, params);
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
        console2.log("weightCarpet", weightCarpet);

        (bool success, int24 resultRoundedTick) = LibCarpetedDoubleGeometricDistribution.inverseCumulativeAmount1(
            cumulativeAmount1, liquidity, tickSpacing, params
        );
        if (!success) return;
        console2.log("resultRoundedTick", resultRoundedTick);

        uint256 resultCumulativeAmount1 =
            LibCarpetedDoubleGeometricDistribution.cumulativeAmount1(resultRoundedTick, liquidity, tickSpacing, params);

        assertGe(resultCumulativeAmount1, cumulativeAmount1, "resultCumulativeAmount1 < cumulativeAmount1");

        if (resultRoundedTick > minTick && cumulativeAmount1 > 1e2) {
            uint256 nextCumulativeAmount1 = LibCarpetedDoubleGeometricDistribution.cumulativeAmount1(
                resultRoundedTick - tickSpacing, liquidity, tickSpacing, params
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
        uint32 weightCarpet = 0.9e9;
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
                weight1,
                weightCarpet
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
                weight1,
                weightCarpet
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
                weight1,
                weightCarpet
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
        uint32 weightCarpet = 0.9e9;
        ShiftMode shiftMode = ShiftMode.RIGHT;
        PoolKey memory key;
        key.tickSpacing = tickSpacing;

        // bounded when minTick < minUsableTick
        (int24 offset, int24 length0, int24 length1) = (minUsableTick - tickSpacing, 1, 1);
        bytes32 ldfParams = bytes32(
            abi.encodePacked(
                shiftMode,
                offset,
                int16(length0),
                uint32(alpha0),
                weight0,
                int16(length1),
                uint32(alpha1),
                weight1,
                weightCarpet
            )
        );
        assertTrue(ldf.isValidParams(key, 1, ldfParams, LDFType.DYNAMIC_AND_STATEFUL), "invalid params 0");
        LibCarpetedDoubleGeometricDistribution.Params memory params =
            LibCarpetedDoubleGeometricDistribution.decodeParams(0, tickSpacing, ldfParams);
        assertEq(params.minTick, minUsableTick, "minTick incorrect");
        assertTrue(params.shiftMode == shiftMode, "shiftMode incorrect");

        // bounded when maxTick > maxUsableTick
        (offset, length0, length1) = (maxUsableTick - tickSpacing, 1, 1);
        ldfParams = ldfParams = bytes32(
            abi.encodePacked(
                shiftMode,
                offset,
                int16(length0),
                uint32(alpha0),
                weight0,
                int16(length1),
                uint32(alpha1),
                weight1,
                weightCarpet
            )
        );
        assertTrue(ldf.isValidParams(key, 1, ldfParams, LDFType.DYNAMIC_AND_STATEFUL), "invalid params 1");
        params = LibCarpetedDoubleGeometricDistribution.decodeParams(0, tickSpacing, ldfParams);
        assertEq(params.minTick + (length0 + length1) * tickSpacing, maxUsableTick, "maxTick incorrect");
        assertTrue(params.shiftMode == shiftMode, "shiftMode incorrect");
    }

    function _test_query_cumulativeAmounts(int24 currentTick, int24 tickSpacing, bytes32 decodedLDFParams)
        internal
        view
        virtual
        override
    {
        int24 roundedTick = roundTickSingle(currentTick, tickSpacing);
        PoolKey memory key;
        key.tickSpacing = tickSpacing;
        (, uint256 cumulativeAmount0DensityX96, uint256 cumulativeAmount1DensityX96,,) =
            ldf.query(key, roundedTick, 0, currentTick, decodedLDFParams, LDF_STATE);
        uint256 cumulativeAmount0 = ldf.cumulativeAmount0(
            key,
            roundedTick + tickSpacing,
            FixedPoint96.Q96 << QUERY_SCALE_SHIFT,
            0,
            currentTick,
            decodedLDFParams,
            LDF_STATE
        ) >> QUERY_SCALE_SHIFT;
        uint256 cumulativeAmount1 = ldf.cumulativeAmount1(
            key,
            roundedTick - tickSpacing,
            FixedPoint96.Q96 << QUERY_SCALE_SHIFT,
            0,
            currentTick,
            decodedLDFParams,
            LDF_STATE
        ) >> QUERY_SCALE_SHIFT;
        assertEq(cumulativeAmount0, cumulativeAmount0DensityX96, "cumulativeAmount0 incorrect");
        assertEq(cumulativeAmount1, cumulativeAmount1DensityX96, "cumulativeAmount1 incorrect");
        uint256 bruteForceAmount0X96 =
            _bruteForceCumulativeAmount0Density(roundedTick + tickSpacing, tickSpacing, decodedLDFParams);
        uint256 bruteForceAmount1X96 =
            _bruteForceCumulativeAmount1Density(roundedTick - tickSpacing, tickSpacing, decodedLDFParams);

        (, uint256 error0) = absDiff(cumulativeAmount0DensityX96, bruteForceAmount0X96);
        if (error0 > MIN_ABS_ERROR) {
            assertApproxEqRel(
                cumulativeAmount0DensityX96,
                bruteForceAmount0X96,
                MAX_ERROR_CUM0,
                "cumulativeAmount0DensityX96 incorrect"
            );
        }

        (, uint256 error1) = absDiff(cumulativeAmount1DensityX96, bruteForceAmount1X96);
        if (error1 > MIN_ABS_ERROR) {
            assertApproxEqRel(
                cumulativeAmount1DensityX96,
                bruteForceAmount1X96,
                MAX_ERROR_CUM1,
                "cumulativeAmount1DensityX96 incorrect"
            );
        }
    }
}
