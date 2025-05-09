// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import "forge-std/console2.sol";

import "../src/ldf/LibUniformDistribution.sol";
import "../src/ldf/LibGeometricDistribution.sol";
import "../src/ldf/DoubleGeometricDistribution.sol";
import "../src/ldf/CarpetedGeometricDistribution.sol";
import "../src/ldf/CarpetedDoubleGeometricDistribution.sol";
import "./FuzzHelper.sol";
import "./PropertiesAsserts.sol";

contract FuzzLDF is FuzzHelper, PropertiesAsserts {
    uint256 internal constant INVCUM_MIN_MAX_CUM_AMOUNT = 1e6;

    uint256 uniform_dist_0_failures;
    uint256 uniform_dist_1_failures;
    uint256 geometric_dist_0_failures;
    uint256 geometric_dist_1_failures;

    // Invariant: Given a valid cumulative amount of token0, the cumulative amount calculated
    //            using the rounded tick from inverseCommulativeAmount0() should be greater than
    //            or equal to the specified cumulative amount for UniformDistribution in rounded
    //            ticks [roundedTick, tickUpper).
    // Issue: TOB-BUNNI-19
    function inverse_cummulative_amount0_greater_than_equal_to_cummulative_amount0_in_uniform_distribution(
        int24 tickSpacing,
        uint256 totalLiquidity,
        uint256 cumulativeAmount0,
        int24 tickLower,
        int24 tickUpper
    ) public {
        totalLiquidity = clampBetween(totalLiquidity, 1e18, 1e36);
        tickSpacing = int24(clampBetween(tickSpacing, MIN_TICK_SPACING, MAX_TICK_SPACING));
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
        tickLower =
            roundTickSingle(int24(clampBetween(tickLower, minUsableTick, maxUsableTick - tickSpacing)), tickSpacing);
        tickUpper = roundTickSingle(int24(clampBetween(tickUpper, tickLower + tickSpacing, maxUsableTick)), tickSpacing);

        PoolKey memory key;
        key.tickSpacing = tickSpacing;
        bytes32 ldfParams = bytes32(abi.encodePacked(ShiftMode.STATIC, tickLower, tickUpper));
        if (!LibUniformDistribution.isValidParams(tickSpacing, 0, ldfParams, LDFType.STATIC)) {
            return;
        }

        uint256 maxCumulativeAmount0 = LibUniformDistribution.cumulativeAmount0(
            minUsableTick, totalLiquidity, tickSpacing, tickLower, tickUpper, false
        );
        if (maxCumulativeAmount0 < INVCUM_MIN_MAX_CUM_AMOUNT) return;

        cumulativeAmount0 = clampBetween(cumulativeAmount0, 0, maxCumulativeAmount0);
        (bool success, int24 resultRoundedTick) = LibUniformDistribution.inverseCumulativeAmount0(
            cumulativeAmount0, totalLiquidity, tickSpacing, tickLower, tickUpper, false
        );
        if (!success) return;
        uint256 resultCumulativeAmount0 = LibUniformDistribution.cumulativeAmount0(
            resultRoundedTick, totalLiquidity, tickSpacing, tickLower, tickUpper, false
        );

        assertGte(resultCumulativeAmount0, cumulativeAmount0, "resultCumulativeAmount0 < cumulativeAmount0");

        if (resultRoundedTick < tickUpper && cumulativeAmount0 > 3e4) {
            // NOTE: when cumulativeAmount0 is small this assertion may fail due to rounding errors
            uint256 nextCumulativeAmount0 = LibUniformDistribution.cumulativeAmount0(
                resultRoundedTick + tickSpacing, totalLiquidity, tickSpacing, tickLower, tickUpper, false
            );
            assertLt(nextCumulativeAmount0, cumulativeAmount0, "nextCumulativeAmount0 >= cumulativeAmount0");
        }
    }
    // Invariant: Given a valid cumulative amount of token1, the cumulative amount calculated
    //            using the rounded tick from inverseCommulativeAmount1() should be greater than
    //            or equal to the specified cumulative amount for UniformDistribution in rounded
    //            ticks [tickLower,roundedTick).

    function inverse_cummulative_amount1_less_than_equal_to_cummulative_amount1_in_uniform_distribution(
        uint256 totalLiquidity,
        uint256 cumulativeAmount1,
        int24 tickSpacing,
        int24 tickLower,
        int24 tickUpper
    ) external virtual {
        totalLiquidity = clampBetween(totalLiquidity, 1e18, 1e36);
        tickSpacing = int24(clampBetween(tickSpacing, MIN_TICK_SPACING, MAX_TICK_SPACING));
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
        tickLower =
            roundTickSingle(int24(clampBetween(tickLower, minUsableTick, maxUsableTick - tickSpacing)), tickSpacing);
        tickUpper = roundTickSingle(int24(clampBetween(tickUpper, tickLower + tickSpacing, maxUsableTick)), tickSpacing);

        PoolKey memory key;
        key.tickSpacing = tickSpacing;
        bytes32 ldfParams = bytes32(abi.encodePacked(ShiftMode.STATIC, tickLower, tickUpper));
        if (!LibUniformDistribution.isValidParams(tickSpacing, 0, ldfParams, LDFType.STATIC)) {
            return;
        }

        uint256 maxCumulativeAmount1 = LibUniformDistribution.cumulativeAmount1(
            maxUsableTick, totalLiquidity, tickSpacing, tickLower, tickUpper, false
        );
        if (maxCumulativeAmount1 < INVCUM_MIN_MAX_CUM_AMOUNT) return;

        cumulativeAmount1 = clampBetween(cumulativeAmount1, 0, maxCumulativeAmount1);

        (bool success, int24 resultRoundedTick) = LibUniformDistribution.inverseCumulativeAmount1(
            cumulativeAmount1, totalLiquidity, tickSpacing, tickLower, tickUpper, false
        );
        if (!success) return;

        uint256 resultCumulativeAmount1 = LibUniformDistribution.cumulativeAmount1(
            resultRoundedTick, totalLiquidity, tickSpacing, tickLower, tickUpper, false
        );
        assertGte(resultCumulativeAmount1, cumulativeAmount1, "resultCumulativeAmount1 < cumulativeAmount1");

        if (resultRoundedTick > tickLower && cumulativeAmount1 > 1e4) {
            uint256 nextCumulativeAmount1 = LibUniformDistribution.cumulativeAmount1(
                resultRoundedTick - tickSpacing, totalLiquidity, tickSpacing, tickLower, tickUpper, false
            );
            assertLt(nextCumulativeAmount1, cumulativeAmount1, "nextCumulativeAmount1 >= cumulativeAmount1");
        }
    }

    // Invariant: Given a valid cumulative amount of token0, the cumulative amount calculated
    //            using the rounded tick from inverseCommulativeAmount0() should be less than
    //            or equal to the specified cumulative amount for GeometricDistribution in rounded
    //            ticks [roundedTick, tickUpper).
    function inverse_cummulative_amount0_greater_than_equal_to_cummulative_amount0_in_geometric_distribution(
        int24 tickSpacing,
        uint256 totalLiquidity,
        uint256 cumulativeAmount0,
        int24 minTick,
        int24 length,
        uint256 alpha
    ) public {
        totalLiquidity = clampBetween(totalLiquidity, 1e18, 1e36);
        alpha = clampBetween(alpha, MIN_ALPHA, MAX_ALPHA);
        if (alpha == 1e8) return; // 1e8 is a special case that causes overflow
        tickSpacing = int24(clampBetween(tickSpacing, MIN_TICK_SPACING, MAX_TICK_SPACING));
        uint256 alphaX96 = (alpha << 96) / 1e8;
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
        minTick =
            roundTickSingle(int24(clampBetween(minTick, minUsableTick, maxUsableTick - 2 * tickSpacing)), tickSpacing);
        length = int24(clampBetween(length, 1, maxUsableTick / tickSpacing));

        PoolKey memory key;
        key.tickSpacing = tickSpacing;

        bytes32 ldfParams = bytes32(abi.encodePacked(ShiftMode.STATIC, minTick, int16(length), uint32(alpha)));
        if (!LibGeometricDistribution.isValidParams(tickSpacing, 0, ldfParams, LDFType.STATIC)) {
            return;
        }

        uint256 maxCumulativeAmount0 = LibGeometricDistribution.cumulativeAmount0(
            minUsableTick, totalLiquidity, tickSpacing, minTick, length, alphaX96
        );
        if (maxCumulativeAmount0 < INVCUM_MIN_MAX_CUM_AMOUNT) return;
        cumulativeAmount0 = clampBetween(cumulativeAmount0, 0, maxCumulativeAmount0);

        (bool success, int24 resultRoundedTick) = LibGeometricDistribution.inverseCumulativeAmount0(
            cumulativeAmount0, totalLiquidity, tickSpacing, minTick, length, alphaX96
        );

        if (!success) return;
        uint256 resultCumulativeAmount0 = LibGeometricDistribution.cumulativeAmount0(
            resultRoundedTick, totalLiquidity, tickSpacing, minTick, length, alphaX96
        );
        assertGte(resultCumulativeAmount0, cumulativeAmount0, "resultCumulativeAmount0 < cumulativeAmount0");

        if (resultRoundedTick < minTick + length * tickSpacing && cumulativeAmount0 > 1e3) {
            uint256 nextCumulativeAmount0 = LibGeometricDistribution.cumulativeAmount0(
                resultRoundedTick + tickSpacing, totalLiquidity, tickSpacing, minTick, length, alphaX96
            );
            assertLt(nextCumulativeAmount0, cumulativeAmount0, "nextCumulativeAmount0 >= cumulativeAmount0");
        }
    }

    // Invariant: Given a valid cumulative amount of token1, the cumulative amount calculated
    //            using the rounded tick from inverseCommulativeAmount1() should be greater than
    //            or equal to the specified cumulative amount for GeometricDistribution in rounded
    //            ticks [tickLower,roundedTick).
    function inverse_cummulative_amount1_greater_than_equal_to_cummulative_amount1_in_geometric_distribution(
        uint256 totalLiquidity,
        uint256 cumulativeAmount1,
        int24 tickSpacing,
        int24 minTick,
        int24 length,
        uint256 alpha
    ) external virtual {
        totalLiquidity = clampBetween(totalLiquidity, 1e18, 1e36);
        alpha = clampBetween(alpha, MIN_ALPHA, MAX_ALPHA);
        if (alpha == 1e8) return; // 1e8 is a special case that causes overflow
        uint256 alphaX96 = (alpha << 96) / 1e8;
        tickSpacing = int24(clampBetween(tickSpacing, MIN_TICK_SPACING, MAX_TICK_SPACING));
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
        minTick =
            roundTickSingle(int24(clampBetween(minTick, minUsableTick, maxUsableTick - 2 * tickSpacing)), tickSpacing);
        length = int24(clampBetween(length, 1, maxUsableTick / tickSpacing));

        PoolKey memory key;
        key.tickSpacing = tickSpacing;
        bytes32 ldfParams = bytes32(abi.encodePacked(ShiftMode.STATIC, minTick, int16(length), uint32(alpha)));
        if (!LibGeometricDistribution.isValidParams(key.tickSpacing, 0, ldfParams, LDFType.STATIC)) return;

        uint256 maxCumulativeAmount1 = LibGeometricDistribution.cumulativeAmount1(
            maxUsableTick, totalLiquidity, tickSpacing, minTick, length, alphaX96
        );
        if (maxCumulativeAmount1 < INVCUM_MIN_MAX_CUM_AMOUNT) return;
        cumulativeAmount1 = clampBetween(cumulativeAmount1, 0, maxCumulativeAmount1);

        (bool success, int24 resultRoundedTick) = LibGeometricDistribution.inverseCumulativeAmount1(
            cumulativeAmount1, totalLiquidity, tickSpacing, minTick, length, alphaX96
        );
        if (!success) return;

        uint256 resultCumulativeAmount1 = LibGeometricDistribution.cumulativeAmount1(
            resultRoundedTick, totalLiquidity, tickSpacing, minTick, length, alphaX96
        );
        assertGte(resultCumulativeAmount1, cumulativeAmount1, "resultCumulativeAmount1 < cumulativeAmount1");

        if (resultRoundedTick > minTick && cumulativeAmount1 > 1e3) {
            uint256 nextCumulativeAmount1 = LibGeometricDistribution.cumulativeAmount1(
                resultRoundedTick - tickSpacing, totalLiquidity, tickSpacing, minTick, length, alphaX96
            );
            assertLt(nextCumulativeAmount1, cumulativeAmount1, "nextCumulativeAmount1 >= cumulativeAmount1");
        }
    }

    // Invariant: Given a valid cumulative amount of token0, the cumulative amount calculated
    //            using the rounded tick from inverseCommulativeAmount0() should be less than
    //            or equal to the specified cumulative amount for DoubleGeometricDistribution in rounded
    //            ticks [roundedTick, tickUpper).
    function inverse_cummulative_amount0_greater_than_equal_to_cummulative_amount0_in_double_geometric(
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
    ) public {
        ldf = ILiquidityDensityFunction(
            address(new DoubleGeometricDistribution(address(this), address(this), address(this)))
        );
        liquidity = clampBetween(liquidity, 1e18, 1e36);
        tickSpacing = int24(clampBetween(tickSpacing, MIN_TICK_SPACING, MAX_TICK_SPACING));
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));

        weight0 = uint32(clampBetween(weight0, 1, 1e6));
        weight1 = uint32(clampBetween(weight1, 1, 1e6));

        alpha1 = clampBetween(alpha1, MIN_ALPHA, MAX_ALPHA);
        require(alpha1 != 1e8); // 1e8 is a special case that causes overflow
        minTick =
            roundTickSingle(int24(clampBetween(minTick, minUsableTick, maxUsableTick - 2 * tickSpacing)), tickSpacing);
        length1 = int24(clampBetween(length1, 1, (maxUsableTick - minTick) / tickSpacing - 1));

        alpha0 = clampBetween(alpha0, MIN_ALPHA, MAX_ALPHA);
        require(alpha0 != 1e8); // 1e8 is a special case that causes overflow
        require((maxUsableTick - (minTick + length1 * tickSpacing)) / tickSpacing - 1 >= 1);
        length0 = int24(clampBetween(length0, 1, (maxUsableTick - (minTick + length1 * tickSpacing)) / tickSpacing - 1));

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
        require(LibDoubleGeometricDistribution.isValidParams(key.tickSpacing, 0, ldfParams, LDFType.STATIC));

        uint256 alpha0X96 = (alpha0 << 96) / 1e8;
        uint256 alpha1X96 = (alpha1 << 96) / 1e8;
        uint256 maxCumulativeAmount0 = LibDoubleGeometricDistribution.cumulativeAmount0(
            minUsableTick, liquidity, tickSpacing, minTick, length0, length1, alpha0X96, alpha1X96, weight0, weight1
        );
        if (maxCumulativeAmount0 < INVCUM_MIN_MAX_CUM_AMOUNT) return;
        cumulativeAmount0 = clampBetween(cumulativeAmount0, 0, maxCumulativeAmount0);

        (bool success, int24 resultRoundedTick) = LibDoubleGeometricDistribution.inverseCumulativeAmount0(
            cumulativeAmount0, liquidity, tickSpacing, minTick, length0, length1, alpha0X96, alpha1X96, weight0, weight1
        );
        if (!success) return;

        uint256 resultCumulativeAmount0 = LibDoubleGeometricDistribution.cumulativeAmount0(
            resultRoundedTick, liquidity, tickSpacing, minTick, length0, length1, alpha0X96, alpha1X96, weight0, weight1
        );

        assertGte(resultCumulativeAmount0, cumulativeAmount0, "resultCumulativeAmount0 < cumulativeAmount0");

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

    // Invariant: Given a valid cumulative amount of token1, the cumulative amount calculated
    //            using the rounded tick from inverseCommulativeAmount1() should be greater than
    //            or equal to the specified cumulative amount for DoubleGeometricDistribution in rounded
    //            ticks [tickLower,roundedTick).
    function inverse_cummulative_amount1_greater_than_equal_to_cummulative_amount1_in_double_geometric(
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
        ldf = ILiquidityDensityFunction(
            address(new DoubleGeometricDistribution(address(this), address(this), address(this)))
        );
        liquidity = clampBetween(liquidity, 1e18, 1e36);
        tickSpacing = int24(clampBetween(tickSpacing, MIN_TICK_SPACING, MAX_TICK_SPACING));
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));

        weight0 = uint32(clampBetween(weight0, 1, 1e6));
        weight1 = uint32(clampBetween(weight1, 1, 1e6));

        alpha1 = clampBetween(alpha1, MIN_ALPHA, MAX_ALPHA);
        require(alpha1 != 1e8); // 1e8 is a special case that causes overflow
        minTick =
            roundTickSingle(int24(clampBetween(minTick, minUsableTick, maxUsableTick - 2 * tickSpacing)), tickSpacing);
        length1 = int24(clampBetween(length1, 1, (maxUsableTick - minTick) / tickSpacing - 1));

        alpha0 = clampBetween(alpha0, MIN_ALPHA, MAX_ALPHA);
        require(alpha0 != 1e8); // 1e8 is a special case that causes overflow
        require((maxUsableTick - (minTick + length1 * tickSpacing)) / tickSpacing - 1 >= 1);
        length0 = int24(clampBetween(length0, 1, (maxUsableTick - (minTick + length1 * tickSpacing)) / tickSpacing - 1));

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
        require(LibDoubleGeometricDistribution.isValidParams(key.tickSpacing, 0, ldfParams, LDFType.STATIC));

        uint256 alpha0X96 = (alpha0 << 96) / 1e8;
        uint256 alpha1X96 = (alpha1 << 96) / 1e8;
        uint256 maxCumulativeAmount1 = LibDoubleGeometricDistribution.cumulativeAmount1(
            maxUsableTick, liquidity, tickSpacing, minTick, length0, length1, alpha0X96, alpha1X96, weight0, weight1
        );
        if (maxCumulativeAmount1 < INVCUM_MIN_MAX_CUM_AMOUNT) return;
        cumulativeAmount1 = clampBetween(cumulativeAmount1, 0, maxCumulativeAmount1);

        (bool success, int24 resultRoundedTick) = LibDoubleGeometricDistribution.inverseCumulativeAmount1(
            cumulativeAmount1, liquidity, tickSpacing, minTick, length0, length1, alpha0X96, alpha1X96, weight0, weight1
        );
        if (!success) return;

        uint256 resultCumulativeAmount1 = LibDoubleGeometricDistribution.cumulativeAmount1(
            resultRoundedTick, liquidity, tickSpacing, minTick, length0, length1, alpha0X96, alpha1X96, weight0, weight1
        );
        assertGte(resultCumulativeAmount1, cumulativeAmount1, "resultCumulativeAmount1 < cumulativeAmount1");

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
    // Invariant: Given a valid cumulative amount of token0, the cumulative amount calculated
    //            using the rounded tick from inverseCommulativeAmount0() should be less than
    //            or equal to the specified cumulative amount for CarpetedGeometricDistribution in rounded
    //            ticks [roundedTick, tickUpper).

    function inverse_cummulative_amount0_greater_than_equal_to_cummulative_amount0_in_carpeted_geometric(
        uint256 liquidity,
        uint256 cumulativeAmount0,
        int24 tickSpacing,
        int24 minTick,
        int24 length,
        uint256 alpha,
        uint256 weightCarpet
    ) external virtual {
        liquidity = clampBetween(liquidity, 1e18, 1e36);
        ldf = ILiquidityDensityFunction(
            address(new CarpetedGeometricDistribution(address(this), address(this), address(this)))
        );
        alpha = clampBetween(alpha, MIN_ALPHA, MAX_ALPHA);
        require(alpha != 1e8); // 1e8 is a special case that causes overflow
        tickSpacing = int24(clampBetween(tickSpacing, MIN_TICK_SPACING, MAX_TICK_SPACING));
        uint256 alphaX96 = (alpha << 96) / 1e8;
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
        minTick =
            roundTickSingle(int24(clampBetween(minTick, minUsableTick, maxUsableTick - 2 * tickSpacing)), tickSpacing);
        length = int24(clampBetween(length, 1, maxUsableTick / tickSpacing));
        weightCarpet = clampBetween(weightCarpet, 1e9, type(uint32).max);

        PoolKey memory key;
        key.tickSpacing = tickSpacing;
        bytes32 ldfParams =
            bytes32(abi.encodePacked(ShiftMode.STATIC, minTick, int16(length), uint32(alpha), uint32(weightCarpet)));
        require(ldf.isValidParams(key, 0, ldfParams, LDFType.STATIC));

        uint256 maxCumulativeAmount0 = LibCarpetedGeometricDistribution.cumulativeAmount0(
            minUsableTick, liquidity, tickSpacing, minTick, length, alphaX96, weightCarpet
        );
        if (maxCumulativeAmount0 < INVCUM_MIN_MAX_CUM_AMOUNT) return;
        cumulativeAmount0 = clampBetween(cumulativeAmount0, 0, maxCumulativeAmount0);

        (bool success, int24 resultRoundedTick) = LibCarpetedGeometricDistribution.inverseCumulativeAmount0(
            cumulativeAmount0, liquidity, tickSpacing, minTick, length, alphaX96, weightCarpet
        );
        if (!success) return;

        uint256 resultCumulativeAmount0 = LibCarpetedGeometricDistribution.cumulativeAmount0(
            resultRoundedTick, liquidity, tickSpacing, minTick, length, alphaX96, weightCarpet
        );

        assertGte(resultCumulativeAmount0, cumulativeAmount0, "resultCumulativeAmount0 < cumulativeAmount0");

        if (resultRoundedTick < minTick + length * tickSpacing && cumulativeAmount0 > 1e4) {
            uint256 nextCumulativeAmount0 = LibCarpetedGeometricDistribution.cumulativeAmount0(
                resultRoundedTick + tickSpacing, liquidity, tickSpacing, minTick, length, alphaX96, weightCarpet
            );
            assertLt(nextCumulativeAmount0, cumulativeAmount0, "nextCumulativeAmount0 >= cumulativeAmount0");
        }
    }

    // Invariant: Given a valid cumulative amount of token1, the cumulative amount calculated
    //            using the rounded tick from inverseCommulativeAmount1() should be greater than
    //            or equal to the specified cumulative amount for CarpetedGeometricDistribution in rounded
    //            ticks [tickLower,roundedTick).
    function inverse_cummulative_amount1_greater_than_equal_to_cummulative_amount1_in_carpeted_geometric(
        uint256 liquidity,
        uint256 cumulativeAmount1,
        int24 tickSpacing,
        int24 minTick,
        int24 length,
        uint256 alpha,
        uint256 weightCarpet
    ) external virtual {
        liquidity = clampBetween(liquidity, 1e18, 1e36);
        ldf = ILiquidityDensityFunction(
            address(new CarpetedGeometricDistribution(address(this), address(this), address(this)))
        );
        alpha = clampBetween(alpha, MIN_ALPHA, MAX_ALPHA);
        require(alpha != 1e8); // 1e8 is a special case that causes overflow
        uint256 alphaX96 = (alpha << 96) / 1e8;
        tickSpacing = int24(clampBetween(tickSpacing, MIN_TICK_SPACING, MAX_TICK_SPACING));
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
        minTick =
            roundTickSingle(int24(clampBetween(minTick, minUsableTick, maxUsableTick - 2 * tickSpacing)), tickSpacing);
        length = int24(clampBetween(length, 1, maxUsableTick / tickSpacing));
        weightCarpet = clampBetween(weightCarpet, 1e9, type(uint32).max);

        PoolKey memory key;
        key.tickSpacing = tickSpacing;
        bytes32 ldfParams =
            bytes32(abi.encodePacked(ShiftMode.STATIC, minTick, int16(length), uint32(alpha), uint32(weightCarpet)));
        require(ldf.isValidParams(key, 0, ldfParams, LDFType.STATIC));

        uint256 maxCumulativeAmount1 = LibCarpetedGeometricDistribution.cumulativeAmount1(
            maxUsableTick, liquidity, tickSpacing, minTick, length, alphaX96, weightCarpet
        );
        if (maxCumulativeAmount1 < INVCUM_MIN_MAX_CUM_AMOUNT) return;
        cumulativeAmount1 = clampBetween(cumulativeAmount1, 0, maxCumulativeAmount1);

        (bool success, int24 resultRoundedTick) = LibCarpetedGeometricDistribution.inverseCumulativeAmount1(
            cumulativeAmount1, liquidity, tickSpacing, minTick, length, alphaX96, weightCarpet
        );
        if (!success) return;

        uint256 resultCumulativeAmount1 = LibCarpetedGeometricDistribution.cumulativeAmount1(
            resultRoundedTick, liquidity, tickSpacing, minTick, length, alphaX96, weightCarpet
        );

        assertGte(resultCumulativeAmount1, cumulativeAmount1, "resultCumulativeAmount1 < cumulativeAmount1");

        if (resultRoundedTick > minTick && cumulativeAmount1 > 5e4) {
            uint256 nextCumulativeAmount1 = LibCarpetedGeometricDistribution.cumulativeAmount1(
                resultRoundedTick - tickSpacing, liquidity, tickSpacing, minTick, length, alphaX96, weightCarpet
            );
            assertLt(nextCumulativeAmount1, cumulativeAmount1, "nextCumulativeAmount1 >= cumulativeAmount1");
        }
    }

    // Invariant: Given a valid cumulative amount of token0, the cumulative amount calculated
    //            using the rounded tick from inverseCommulativeAmount0() should be less than
    //            or equal to the specified cumulative amount for CarpetedDoubleGeometricDistribution
    //            in rounded ticks [roundedTick, tickUpper).
    function inverse_cummulative_amount0_greater_than_equal_to_cummulative_amount0_in_carpeted_double_geometric(
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
        liquidity = clampBetween(liquidity, 1e18, 1e36);
        ldf = ILiquidityDensityFunction(
            address(new CarpetedDoubleGeometricDistribution(address(this), address(this), address(this)))
        );
        tickSpacing = int24(clampBetween(tickSpacing, MIN_TICK_SPACING, MAX_TICK_SPACING));
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));

        weight0 = uint32(clampBetween(weight0, 1, 1e6));
        weight1 = uint32(clampBetween(weight1, 1, 1e6));

        alpha1 = clampBetween(alpha1, MIN_ALPHA, MAX_ALPHA);
        require(alpha1 != 1e8); // 1e8 is a special case that causes overflow
        minTick =
            roundTickSingle(int24(clampBetween(minTick, minUsableTick, maxUsableTick - 2 * tickSpacing)), tickSpacing);
        length1 = int24(clampBetween(length1, 1, (maxUsableTick - minTick) / tickSpacing - 1));

        alpha0 = clampBetween(alpha0, MIN_ALPHA, MAX_ALPHA);
        require(alpha0 != 1e8); // 1e8 is a special case that causes overflow
        require((maxUsableTick - (minTick + length1 * tickSpacing)) / tickSpacing - 1 >= 1);
        length0 = int24(clampBetween(length0, 1, (maxUsableTick - (minTick + length1 * tickSpacing)) / tickSpacing - 1));

        weightCarpet = clampBetween(weightCarpet, 1, type(uint32).max);

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
        require(ldf.isValidParams(key, 0, ldfParams, LDFType.STATIC));

        LibCarpetedDoubleGeometricDistribution.Params memory params =
            LibCarpetedDoubleGeometricDistribution.decodeParams(minTick, tickSpacing, ldfParams);
        uint256 maxCumulativeAmount0 =
            LibCarpetedDoubleGeometricDistribution.cumulativeAmount0(minUsableTick, liquidity, tickSpacing, params);
        if (maxCumulativeAmount0 < INVCUM_MIN_MAX_CUM_AMOUNT) return;
        cumulativeAmount0 = clampBetween(cumulativeAmount0, 0, maxCumulativeAmount0);

        (bool success, int24 resultRoundedTick) = LibCarpetedDoubleGeometricDistribution.inverseCumulativeAmount0(
            cumulativeAmount0, liquidity, tickSpacing, params
        );
        if (!success) return;

        uint256 resultCumulativeAmount0 =
            LibCarpetedDoubleGeometricDistribution.cumulativeAmount0(resultRoundedTick, liquidity, tickSpacing, params);

        assertGte(resultCumulativeAmount0, cumulativeAmount0, "resultCumulativeAmount0 < cumulativeAmount0");

        console2.log("resultCumulativeAmount0", resultCumulativeAmount0);

        if (resultRoundedTick < minTick + length0 * tickSpacing + length1 * tickSpacing && cumulativeAmount0 > 1e4) {
            uint256 nextCumulativeAmount0 = LibCarpetedDoubleGeometricDistribution.cumulativeAmount0(
                resultRoundedTick + tickSpacing, liquidity, tickSpacing, params
            );
            assertLt(nextCumulativeAmount0, cumulativeAmount0, "nextCumulativeAmount0 >= cumulativeAmount0");
        }
    }

    // Invariant: Given a valid cumulative amount of token1, the cumulative amount calculated
    //            using the rounded tick from inverseCommulativeAmount1() should be greater than
    //            or equal to the specified cumulative amount for UniformDistribution in rounded
    //            ticks [tickLower,roundedTick).
    function inverse_cummulative_amount1_greater_than_equal_to_cummulative_amount1_in_carpeted_double_geometric(
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
        liquidity = clampBetween(liquidity, 1e18, 1e36);
        ldf = ILiquidityDensityFunction(
            address(new CarpetedDoubleGeometricDistribution(address(this), address(this), address(this)))
        );
        tickSpacing = int24(clampBetween(tickSpacing, MIN_TICK_SPACING, MAX_TICK_SPACING));
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));

        weight0 = uint32(clampBetween(weight0, 1, 1e6));
        weight1 = uint32(clampBetween(weight1, 1, 1e6));

        alpha1 = clampBetween(alpha1, MIN_ALPHA, MAX_ALPHA);
        require(alpha1 != 1e8); // 1e8 is a special case that causes overflow
        minTick =
            roundTickSingle(int24(clampBetween(minTick, minUsableTick, maxUsableTick - 2 * tickSpacing)), tickSpacing);
        length1 = int24(clampBetween(length1, 1, (maxUsableTick - minTick) / tickSpacing - 1));

        alpha0 = clampBetween(alpha0, MIN_ALPHA, MAX_ALPHA);
        require(alpha0 != 1e8); // 1e8 is a special case that causes overflow
        require((maxUsableTick - (minTick + length1 * tickSpacing)) / tickSpacing - 1 >= 1);
        length0 = int24(clampBetween(length0, 1, (maxUsableTick - (minTick + length1 * tickSpacing)) / tickSpacing - 1));

        weightCarpet = clampBetween(weightCarpet, 1, type(uint32).max);

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
        require(ldf.isValidParams(key, 0, ldfParams, LDFType.STATIC));

        LibCarpetedDoubleGeometricDistribution.Params memory params =
            LibCarpetedDoubleGeometricDistribution.decodeParams(minTick, tickSpacing, ldfParams);
        uint256 maxCumulativeAmount1 =
            LibCarpetedDoubleGeometricDistribution.cumulativeAmount1(maxUsableTick, liquidity, tickSpacing, params);
        if (maxCumulativeAmount1 < INVCUM_MIN_MAX_CUM_AMOUNT) return;
        cumulativeAmount1 = clampBetween(cumulativeAmount1, 0, maxCumulativeAmount1);

        (bool success, int24 resultRoundedTick) = LibCarpetedDoubleGeometricDistribution.inverseCumulativeAmount1(
            cumulativeAmount1, liquidity, tickSpacing, params
        );
        if (!success) return;

        uint256 resultCumulativeAmount1 =
            LibCarpetedDoubleGeometricDistribution.cumulativeAmount1(resultRoundedTick, liquidity, tickSpacing, params);

        assertGte(resultCumulativeAmount1, cumulativeAmount1, "resultCumulativeAmount1 < cumulativeAmount1");

        if (resultRoundedTick > minTick && cumulativeAmount1 > 1e3) {
            uint256 nextCumulativeAmount1 = LibCarpetedDoubleGeometricDistribution.cumulativeAmount1(
                resultRoundedTick - tickSpacing, liquidity, tickSpacing, params
            );
            assertLt(nextCumulativeAmount1, cumulativeAmount1, "nextCumulativeAmount1 >= cumulativeAmount1");
        }
    }
}
