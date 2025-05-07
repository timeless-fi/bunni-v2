// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import {console2} from "forge-std/console2.sol";

import "./LiquidityDensityFunctionTest.sol";
import "../../src/ldf/UniformDistribution.sol";
import "../../src/ldf/LibUniformDistribution.sol";

contract UniformDistributionTest is LiquidityDensityFunctionTest {
    uint256 internal constant INVCUM_MIN_MAX_CUM_AMOUNT = 1e1;

    function _setUpLDF() internal override {
        ldf = ILiquidityDensityFunction(address(new UniformDistribution(address(this), address(this), address(this))));
    }

    function test_liquidityDensity_sumUpToOne(int24 tickSpacing, int24 tickLower, int24 tickUpper) external virtual {
        tickSpacing = int24(bound(tickSpacing, MIN_TICK_SPACING, MAX_TICK_SPACING));
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
        tickLower = roundTickSingle(int24(bound(tickLower, minUsableTick, maxUsableTick - tickSpacing)), tickSpacing);
        tickUpper = roundTickSingle(int24(bound(tickUpper, tickLower + tickSpacing, maxUsableTick)), tickSpacing);

        console2.log("tickSpacing", tickSpacing);
        console2.log("tickLower", tickLower);
        console2.log("tickUpper", tickUpper);

        PoolKey memory key;
        key.tickSpacing = tickSpacing;
        bytes32 ldfParams = bytes32(abi.encodePacked(ShiftMode.STATIC, tickLower, tickUpper));
        vm.assume(ldf.isValidParams(key, 0, ldfParams));
        _test_liquidityDensity_sumUpToOne(tickSpacing, ldfParams);
    }

    function test_query_cumulativeAmounts(int24 currentTick, int24 tickSpacing, int24 tickLower, int24 tickUpper)
        external
        virtual
    {
        tickSpacing = int24(bound(tickSpacing, MIN_TICK_SPACING, MAX_TICK_SPACING));
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
        tickLower = roundTickSingle(int24(bound(tickLower, minUsableTick, maxUsableTick - tickSpacing)), tickSpacing);
        tickUpper = roundTickSingle(int24(bound(tickUpper, tickLower + tickSpacing, maxUsableTick)), tickSpacing);
        currentTick = int24(bound(currentTick, minUsableTick, maxUsableTick));

        console2.log("tickSpacing", tickSpacing);
        console2.log("tickLower", tickLower);
        console2.log("tickUpper", tickUpper);
        console2.log("currentTick", currentTick);

        PoolKey memory key;
        key.tickSpacing = tickSpacing;
        bytes32 ldfParams = bytes32(abi.encodePacked(ShiftMode.STATIC, tickLower, tickUpper));
        vm.assume(ldf.isValidParams(key, 0, ldfParams));
        _test_query_cumulativeAmounts(currentTick, tickSpacing, ldfParams);
    }

    function test_inverseCumulativeAmount0(
        uint256 liquidity,
        uint256 cumulativeAmount0,
        int24 tickSpacing,
        int24 tickLower,
        int24 tickUpper
    ) external virtual {
        liquidity = bound(liquidity, 1e18, 1e36);
        tickSpacing = int24(bound(tickSpacing, MIN_TICK_SPACING, MAX_TICK_SPACING));
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
        tickLower = roundTickSingle(int24(bound(tickLower, minUsableTick, maxUsableTick - tickSpacing)), tickSpacing);
        tickUpper = roundTickSingle(int24(bound(tickUpper, tickLower + tickSpacing, maxUsableTick)), tickSpacing);

        PoolKey memory key;
        key.tickSpacing = tickSpacing;
        bytes32 ldfParams = bytes32(abi.encodePacked(ShiftMode.STATIC, tickLower, tickUpper));
        vm.assume(ldf.isValidParams(key, 0, ldfParams));

        uint256 maxCumulativeAmount0 =
            LibUniformDistribution.cumulativeAmount0(minUsableTick, liquidity, tickSpacing, tickLower, tickUpper, false);
        vm.assume(maxCumulativeAmount0 > INVCUM_MIN_MAX_CUM_AMOUNT); // ignore distributions where there's basically 0 tokens
        cumulativeAmount0 = bound(cumulativeAmount0, 0, maxCumulativeAmount0);

        console2.log("cumulativeAmount0", cumulativeAmount0);
        console2.log("maxCumulativeAmount0", maxCumulativeAmount0);
        console2.log("tickSpacing", tickSpacing);
        console2.log("tickLower", tickLower);
        console2.log("tickUpper", tickUpper);

        (bool success, int24 resultRoundedTick) = LibUniformDistribution.inverseCumulativeAmount0(
            cumulativeAmount0, liquidity, tickSpacing, tickLower, tickUpper, false
        );
        if (!success) return;
        console2.log("resultRoundedTick", resultRoundedTick);

        uint256 resultCumulativeAmount0 = LibUniformDistribution.cumulativeAmount0(
            resultRoundedTick, liquidity, tickSpacing, tickLower, tickUpper, false
        );

        assertGe(resultCumulativeAmount0, cumulativeAmount0, "resultCumulativeAmount0 < cumulativeAmount0");

        if (resultRoundedTick < tickUpper && cumulativeAmount0 > 2e4) {
            // NOTE: when cumulativeAmount0 is small this assertion may fail due to rounding errors
            uint256 nextCumulativeAmount0 = LibUniformDistribution.cumulativeAmount0(
                resultRoundedTick + tickSpacing, liquidity, tickSpacing, tickLower, tickUpper, false
            );
            assertLt(nextCumulativeAmount0, cumulativeAmount0, "nextCumulativeAmount0 >= cumulativeAmount0");
        }
    }

    function test_inverseCumulativeAmount1(
        uint256 liquidity,
        uint256 cumulativeAmount1,
        int24 tickSpacing,
        int24 tickLower,
        int24 tickUpper
    ) external virtual {
        liquidity = bound(liquidity, 1e18, 1e36);
        tickSpacing = int24(bound(tickSpacing, MIN_TICK_SPACING, MAX_TICK_SPACING));
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
        tickLower = roundTickSingle(int24(bound(tickLower, minUsableTick, maxUsableTick - tickSpacing)), tickSpacing);
        tickUpper = roundTickSingle(int24(bound(tickUpper, tickLower + tickSpacing, maxUsableTick)), tickSpacing);

        PoolKey memory key;
        key.tickSpacing = tickSpacing;
        bytes32 ldfParams = bytes32(abi.encodePacked(ShiftMode.STATIC, tickLower, tickUpper));
        vm.assume(ldf.isValidParams(key, 0, ldfParams));

        uint256 maxCumulativeAmount1 =
            LibUniformDistribution.cumulativeAmount1(maxUsableTick, liquidity, tickSpacing, tickLower, tickUpper, false);
        vm.assume(maxCumulativeAmount1 > INVCUM_MIN_MAX_CUM_AMOUNT); // ignore distributions where there's basically 0 tokens
        cumulativeAmount1 = bound(cumulativeAmount1, 0, maxCumulativeAmount1);

        console2.log("cumulativeAmount1", cumulativeAmount1);
        console2.log("maxCumulativeAmount1", maxCumulativeAmount1);
        console2.log("tickSpacing", tickSpacing);
        console2.log("tickLower", tickLower);
        console2.log("tickUpper", tickUpper);

        (bool success, int24 resultRoundedTick) = LibUniformDistribution.inverseCumulativeAmount1(
            cumulativeAmount1, liquidity, tickSpacing, tickLower, tickUpper, false
        );
        if (!success) return;
        console2.log("resultRoundedTick", resultRoundedTick);

        uint256 resultCumulativeAmount1 = LibUniformDistribution.cumulativeAmount1(
            resultRoundedTick, liquidity, tickSpacing, tickLower, tickUpper, false
        );

        assertGe(resultCumulativeAmount1, cumulativeAmount1, "resultCumulativeAmount1 < cumulativeAmount1");

        if (resultRoundedTick > tickLower && cumulativeAmount1 > 3e4) {
            uint256 nextCumulativeAmount1 = LibUniformDistribution.cumulativeAmount1(
                resultRoundedTick - tickSpacing, liquidity, tickSpacing, tickLower, tickUpper, false
            );
            assertLt(nextCumulativeAmount1, cumulativeAmount1, "nextCumulativeAmount1 >= cumulativeAmount1");
        }
    }

    function test_boundary_static_invalidWhenOutOfBounds(int24 tickSpacing) external view {
        tickSpacing = int24(bound(tickSpacing, MIN_TICK_SPACING, MAX_TICK_SPACING));
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
        PoolKey memory key;
        key.tickSpacing = tickSpacing;

        // invalid when minTick < minUsableTick
        (int24 tickLower, int24 tickUpper) = (minUsableTick - tickSpacing, minUsableTick + tickSpacing);
        bytes32 ldfParams = bytes32(abi.encodePacked(ShiftMode.STATIC, tickLower, tickUpper));
        assertFalse(ldf.isValidParams(key, 0, ldfParams));

        // invalid when maxTick > maxUsableTick
        (tickLower, tickUpper) = (maxUsableTick - tickSpacing, maxUsableTick + tickSpacing);
        ldfParams = bytes32(abi.encodePacked(ShiftMode.STATIC, tickLower, tickUpper));
        assertFalse(ldf.isValidParams(key, 0, ldfParams));

        // valid test
        (tickLower, tickUpper) = (0, tickSpacing);
        ldfParams = bytes32(abi.encodePacked(ShiftMode.STATIC, tickLower, tickUpper));
        assertTrue(ldf.isValidParams(key, 0, ldfParams));
    }

    function test_boundary_dynamic_boundedWhenDecoding(int24 tickSpacing) external view {
        tickSpacing = int24(bound(tickSpacing, MIN_TICK_SPACING, MAX_TICK_SPACING));
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
        ShiftMode shiftMode = ShiftMode.RIGHT;
        PoolKey memory key;
        key.tickSpacing = tickSpacing;

        // bounded when minTick < minUsableTick
        (int24 offset, int24 length) = (minUsableTick - tickSpacing, 2);
        bytes32 ldfParams = bytes32(abi.encodePacked(shiftMode, offset, length));
        assertTrue(ldf.isValidParams(key, 1, ldfParams), "invalid params 0");
        (int24 tickLower, int24 tickUpper, ShiftMode decodedShiftMode) =
            LibUniformDistribution.decodeParams(0, tickSpacing, ldfParams);
        assertEq(tickLower, minUsableTick, "tickLower incorrect");
        assertTrue(decodedShiftMode == shiftMode, "shiftMode incorrect");

        // bounded when maxTick > maxUsableTick
        (offset, length) = (maxUsableTick - tickSpacing, 2);
        ldfParams = bytes32(abi.encodePacked(shiftMode, offset, length));
        assertTrue(ldf.isValidParams(key, 1, ldfParams), "invalid params 1");
        (tickLower, tickUpper, decodedShiftMode) = LibUniformDistribution.decodeParams(0, tickSpacing, ldfParams);
        assertEq(tickUpper, maxUsableTick, "tickUpper incorrect");
        assertTrue(decodedShiftMode == shiftMode, "shiftMode incorrect");

        // invalid params when minTick < minUsableTick and maxTick > maxUsableTick
        (offset, length) = (minUsableTick - tickSpacing, (maxUsableTick - minUsableTick) / tickSpacing + 2);
        ldfParams = bytes32(abi.encodePacked(shiftMode, offset, length));
        assertFalse(ldf.isValidParams(key, 1, ldfParams), "invalid params 2");
    }

    function test_poc_shiftmode() external virtual {
        int24 tickSpacing = MIN_TICK_SPACING;
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
        int24 tickLower = minUsableTick;
        int24 tickUpper = maxUsableTick;
        int24 length = (tickUpper - minUsableTick) / tickSpacing;
        int24 currentTick = minUsableTick + tickSpacing * 2;
        int24 offset = roundTickSingle(tickLower - currentTick, tickSpacing);
        assertTrue(offset % tickSpacing == 0, "offset not divisible by tickSpacing");

        console2.log("tickSpacing", tickSpacing);
        console2.log("tickLower", tickLower);
        console2.log("tickUpper", tickUpper);
        console2.log("length", length);
        console2.log("currentTick", currentTick);
        console2.log("offset", offset);

        PoolKey memory key;
        key.tickSpacing = tickSpacing;
        bytes32 ldfParams = bytes32(abi.encodePacked(ShiftMode.RIGHT, offset, length));
        assertTrue(ldf.isValidParams(key, 15 minutes, ldfParams));

        bytes32 INITIALIZED_STATE = bytes32(abi.encodePacked(true, currentTick));
        int24 roundedTick = roundTickSingle(currentTick, tickSpacing);
        // vm.expectPartialRevert(0x8b86327a);
        (, uint256 cumulativeAmount0DensityX96, uint256 cumulativeAmount1DensityX96,,) =
            ldf.query(key, roundedTick, 0, currentTick, ldfParams, INITIALIZED_STATE);
    }
}
