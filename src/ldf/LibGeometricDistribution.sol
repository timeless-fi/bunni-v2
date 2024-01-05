// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import {console2} from "forge-std/console2.sol";
import {stdMath} from "forge-std/StdMath.sol";

import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import "./ShiftMode.sol";
import "../lib/Math.sol";
import "../lib/ExpMath.sol";

library LibGeometricDistribution {
    using TickMath for int24;
    using ExpMath for int256;
    using SafeCastLib for int256;
    using SafeCastLib for uint256;
    using FixedPointMathLib for int256;
    using FixedPointMathLib for uint160;
    using FixedPointMathLib for uint256;

    uint256 internal constant ALPHA_BASE = 1e8; // alpha uses 8 decimals in ldfParams
    uint256 internal constant MIN_ALPHA = 1e3;
    uint256 internal constant MAX_ALPHA = 12e8;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant Q96 = 0x1000000000000000000000000;
    uint256 internal constant MIN_LIQUIDITY_DENSITY = Q96 / 1e3;

    function query(int24 roundedTick, int24 tickSpacing, int24 minTick, int24 length, uint256 alphaX96)
        internal
        pure
        returns (uint256 liquidityDensityX96_, uint256 cumulativeAmount0DensityX96, uint256 cumulativeAmount1DensityX96)
    {
        // compute liquidityDensityX96
        liquidityDensityX96_ = liquidityDensityX96(roundedTick, tickSpacing, minTick, length, alphaX96);

        // x is the index of the roundedTick in the distribution
        // should be in the range [0, length)
        int24 x;
        if (roundedTick < minTick) {
            // roundedTick is to the left of the distribution
            // set x = -1
            x = -1;
        } else if (roundedTick >= minTick + length * tickSpacing) {
            // roundedTick is to the right of the distribution
            // set x = length
            x = length;
        } else {
            // roundedTick is in the distribution
            x = (roundedTick - minTick) / tickSpacing;
        }

        uint256 sqrtRatioTickSpacing = tickSpacing.getSqrtRatioAtTick();
        uint256 sqrtRatioNegTickSpacing = (-tickSpacing).getSqrtRatioAtTick();
        uint256 sqrtRatioMinTick = minTick.getSqrtRatioAtTick();
        uint256 sqrtRatioNegMinTick = (-minTick).getSqrtRatioAtTick();

        if (alphaX96 > Q96) {
            // alpha > 1
            // need to make sure that alpha^x doesn't overflow by using alpha^-1 during exponentiation
            uint256 alphaInvX96 = Q96.mulDiv(Q96, alphaX96);

            // compute cumulativeAmount0DensityX96 for the rounded tick to the right of the rounded current tick
            if (x >= length - 1) {
                // roundedTick is the last tick in the distribution
                // cumulativeAmount0DensityX96 is just 0
                cumulativeAmount0DensityX96 = 0;
            } else {
                int24 xPlus1 = x + 1; // the rounded tick to the right of the current rounded tick

                uint256 numerator = stdMath.delta(
                    alphaInvX96.rpow(uint24(length - xPlus1), Q96),
                    (-tickSpacing * (length - xPlus1)).getSqrtRatioAtTick()
                ) * (-tickSpacing * xPlus1).getSqrtRatioAtTick();

                uint256 denominator = stdMath.delta(Q96, alphaX96.mulDiv(sqrtRatioNegTickSpacing, Q96))
                    * (Q96 - alphaInvX96.rpow(uint24(length), Q96));

                cumulativeAmount0DensityX96 = (Q96 - sqrtRatioNegTickSpacing).fullMulDiv(numerator, denominator).mulDiv(
                    alphaX96 - Q96, sqrtRatioMinTick
                );
            }

            // compute cumulativeAmount1DensityX96 for the rounded tick to the left of the rounded current tick
            if (x <= 0) {
                // roundedTick is the first tick in the distribution
                // cumulativeAmount1DensityX96 is just 0
                cumulativeAmount1DensityX96 = 0;
            } else {
                uint256 alphaInvPowLengthX96 = alphaInvX96.rpow(uint24(length), Q96);

                uint256 baseX96 = alphaX96.mulDiv(sqrtRatioTickSpacing, Q96);
                uint256 numerator1 = alphaX96 - Q96;
                uint256 denominator1 = baseX96 - Q96;
                uint256 numerator2 = alphaInvX96.rpow(uint24(length - x), Q96).mulDiv(
                    (x * tickSpacing).getSqrtRatioAtTick(), Q96
                ) - alphaInvPowLengthX96;

                uint256 denominator2 = Q96 - alphaInvPowLengthX96;
                cumulativeAmount1DensityX96 = Q96.mulDiv(numerator1, denominator1).mulDiv(numerator2, denominator2)
                    .mulDiv(sqrtRatioTickSpacing - Q96, sqrtRatioNegMinTick);
            }
        } else {
            // alpha <= 1
            // will revert if alpha == 1 but that's ok

            // compute cumulativeAmount0DensityX96 for the rounded tick to the right of the rounded current tick
            if (x >= length - 1) {
                // roundedTick is the last tick in the distribution
                // cumulativeAmount0DensityX96 is just 0
                cumulativeAmount0DensityX96 = 0;
            } else {
                uint256 baseX96 = alphaX96.mulDiv(sqrtRatioNegTickSpacing, Q96);
                uint256 numerator =
                    (Q96 - alphaX96) * (baseX96.rpow(uint24(x + 1), Q96) - baseX96.rpow(uint24(length), Q96));
                uint256 denominator = (Q96 - alphaX96.rpow(uint24(length), Q96)) * (Q96 - baseX96);
                cumulativeAmount0DensityX96 =
                    (Q96 - sqrtRatioNegTickSpacing).fullMulDiv(numerator, denominator).mulDiv(Q96, sqrtRatioMinTick);
            }

            // compute cumulativeAmount1DensityX96 for the rounded tick to the left of the rounded current tick
            if (x <= 0) {
                // roundedTick is the first tick in the distribution
                // cumulativeAmount1DensityX96 is just 0
                cumulativeAmount1DensityX96 = 0;
            } else {
                uint256 baseX96 = alphaX96.mulDiv(sqrtRatioTickSpacing, Q96);
                uint256 numerator = stdMath.delta(
                    sqrtRatioMinTick,
                    alphaX96.rpow(uint24(x), Q96).mulDiv((x * tickSpacing + minTick).getSqrtRatioAtTick(), Q96)
                ) * (Q96 - alphaX96);
                uint256 denominator = stdMath.delta(Q96, baseX96) * (Q96 - alphaX96.rpow(uint24(length), Q96));
                cumulativeAmount1DensityX96 = (sqrtRatioTickSpacing - Q96).fullMulDiv(numerator, denominator);
            }
        }
    }

    function inverseCumulativeAmount0(
        uint256 cumulativeAmount0,
        uint256 totalLiquidity,
        int24 tickSpacing,
        int24 minTick,
        int24 length,
        uint256 alphaX96
    ) internal pure returns (uint160 sqrtPriceX96) {
        uint256 cumulativeAmount0DensityX96 = cumulativeAmount0.mulDiv(Q96, totalLiquidity);
        if (cumulativeAmount0DensityX96 == 0) {
            // return right boundary of distribution
            return (minTick + length * tickSpacing).getSqrtRatioAtTick();
        }

        uint256 sqrtRatioNegTickSpacing = (-tickSpacing).getSqrtRatioAtTick();
        uint256 sqrtRatioMinTick = minTick.getSqrtRatioAtTick();
        uint256 baseX96 = alphaX96.mulDiv(sqrtRatioNegTickSpacing, Q96);
        int256 lnBaseX96 = int256(baseX96).lnQ96(); // int256 conversion is safe since baseX96 < Q96

        int256 xWad;
        if (alphaX96 > Q96) {
            // alpha > 1
            // need to make sure that alpha^x doesn't overflow by using alpha^-1 during exponentiation
            uint256 alphaInvX96 = Q96.mulDiv(Q96, alphaX96);

            uint256 alphaInvPowLengthX96 = alphaInvX96.rpow(uint24(length), Q96);
            uint256 denominator = stdMath.delta(Q96, baseX96) * (Q96 - alphaInvPowLengthX96);
            uint256 numerator = cumulativeAmount0DensityX96.mulDiv(sqrtRatioMinTick, alphaX96 - Q96).fullMulDiv(
                denominator, Q96 - sqrtRatioNegTickSpacing
            );
            uint256 sqrtRatioNegTickSpacingMulLength = (-tickSpacing * length).getSqrtRatioAtTick();
            uint256 tmpX96 = (
                (
                    Q96 >= baseX96
                        ? (sqrtRatioNegTickSpacingMulLength << 96) + numerator
                        : (sqrtRatioNegTickSpacingMulLength << 96) - numerator
                ) >> 96
            );
            xWad = (tmpX96.toInt256().lnQ96() + int256(length) * int256(alphaX96).lnQ96()).sDivWad(lnBaseX96);
        } else {
            uint256 denominator = (Q96 - alphaX96.rpow(uint24(length), Q96)) * (Q96 - baseX96);
            uint256 numerator = cumulativeAmount0DensityX96.mulDiv(sqrtRatioMinTick, Q96).fullMulDiv(
                denominator, Q96 - sqrtRatioNegTickSpacing
            );
            uint256 basePowXX96 = (numerator / (Q96 - alphaX96) + baseX96.rpow(uint24(length), Q96));
            xWad = basePowXX96.toInt256().lnQ96().sDivWad(lnBaseX96);
        }

        // round xWad to reduce error
        // limits tick precision to 1e-6 of a tick
        int256 remainder = xWad % 1e12;
        xWad = (xWad / 1e12) * 1e12; // clear everything beyond 6 decimals
        // if (remainder > 5e11) xWad += 1e12;
        assembly {
            xWad := add(mul(sgt(remainder, 500000000000), 1000000000000), xWad) // round up if remainder > 0.5
        }

        int256 tickWad = xWad * int256(tickSpacing) + int256(minTick) * int256(WAD);

        sqrtPriceX96 = tickWad.getSqrtRatioAtTickWad();
    }

    function isValidParams(int24 tickSpacing, uint24 twapSecondsAgo, bytes32 ldfParams) internal pure returns (bool) {
        int24 minTick;
        int24 length;
        uint256 alpha;
        if (twapSecondsAgo != 0) {
            // use rounded TWAP value + offset as minTick
            // | offset - 2 bytes | length - 2 bytes | alpha - 4 bytes |
            length = int24(int16(uint16(bytes2(ldfParams << 16))));
            alpha = uint32(bytes4(ldfParams << 32));
        } else {
            // static minTick set in params
            // | minTick - 3 bytes | length - 2 bytes | alpha - 4 bytes | 0 - 2 bytes |
            minTick = int24(uint24(bytes3(ldfParams))); // must be aligned to tickSpacing
            length = int24(int16(uint16(bytes2(ldfParams << 24))));
            alpha = uint32(bytes4(ldfParams << 40));

            // ensure minTick is aligned to tickSpacing
            if (minTick % tickSpacing != 0) return false;
        }

        // ensure alpha is in range
        if (alpha < MIN_ALPHA || alpha > MAX_ALPHA || alpha == ALPHA_BASE) return false;

        // ensure length > 0
        if (length <= 0) return false;

        // ensure length can be contained between minUsableTick and maxUsableTick
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
        if (length > maxUsableTick / tickSpacing || -length < minUsableTick / tickSpacing) return false;

        // ensure liquidity density is nowhere equal to zero
        // can check boundaries since function is monotonic
        uint256 alphaX96 = alpha.mulDiv(Q96, ALPHA_BASE);
        uint256 minLiquidityDensityX96;
        if (alpha > ALPHA_BASE) {
            // monotonically increasing
            // check left boundary
            minLiquidityDensityX96 = liquidityDensityX96(minTick, tickSpacing, minTick, length, alphaX96);
        } else {
            // monotonically decreasing
            // check right boundary
            minLiquidityDensityX96 =
                liquidityDensityX96(minTick + (length - 1) * tickSpacing, tickSpacing, minTick, length, alphaX96);
        }
        if (minLiquidityDensityX96 < MIN_LIQUIDITY_DENSITY) {
            return false;
        }

        // if all conditions are met, return true
        return true;
    }

    function liquidityDensityX96(int24 roundedTick, int24 tickSpacing, int24 minTick, int24 length, uint256 alphaX96)
        internal
        pure
        returns (uint256)
    {
        if (roundedTick < minTick || roundedTick >= minTick + length * tickSpacing) {
            // roundedTick is outside of the distribution
            return 0;
        }
        // x is the index of the roundedTick in the distribution
        // should be in the range [0, length)
        uint256 x = uint24((roundedTick - minTick) / tickSpacing);
        if (alphaX96 > Q96) {
            // alpha > 1
            // need to make sure that alpha^x doesn't overflow by using alpha^-1 during exponentiation
            uint256 alphaInvX96 = Q96.mulDiv(Q96, alphaX96);
            return alphaInvX96.rpow(uint24(length) - x, Q96).fullMulDiv(
                alphaX96 - Q96, Q96 - alphaInvX96.rpow(uint24(length), Q96)
            );
        } else {
            // alpha <= 1
            // will revert if alpha == 1 but that's ok
            return (Q96 - alphaX96).mulDiv(alphaX96.rpow(x, Q96), Q96 - alphaX96.rpow(uint24(length), Q96));
        }
    }

    /// @return minTick The minimum rounded tick of the distribution
    /// @return length The length of the distribution in number of rounded ticks (i.e. the number of ticks / tickSpacing)
    /// @return alphaX96 Parameter of the discrete laplace distribution, FixedPoint96
    function decodeParams(int24 twapTick, int24 tickSpacing, bool useTwap, bytes32 ldfParams)
        internal
        pure
        returns (int24 minTick, int24 length, uint256 alphaX96, ShiftMode shiftMode)
    {
        uint256 alpha;
        if (useTwap) {
            // use rounded TWAP value + offset as minTick
            // | offset - 2 bytes | length - 2 bytes | alpha - 4 bytes | shiftMode - 1 byte |
            int24 offset = int24(int16(uint16(bytes2(ldfParams)))); // the offset applied to the twap tick to get the minTick
            minTick = roundTickSingle(twapTick + offset * tickSpacing, tickSpacing);
            length = int24(int16(uint16(bytes2(ldfParams << 16))));
            alpha = uint32(bytes4(ldfParams << 32));
            shiftMode = ShiftMode(uint8(bytes1(ldfParams << 64)));
        } else {
            // static minTick set in params
            // | minTick - 3 bytes | length - 2 bytes | alpha - 4 bytes |
            minTick = int24(uint24(bytes3(ldfParams))); // must be aligned to tickSpacing
            length = int24(int16(uint16(bytes2(ldfParams << 24))));
            alpha = uint32(bytes4(ldfParams << 40));
            shiftMode = ShiftMode.BOTH;
        }
        alphaX96 = alpha.mulDiv(Q96, ALPHA_BASE);

        // bound distribution to be within the range of usable ticks
        (int24 minUsableTick, int24 maxUsableTick) =
            (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
        if (minTick < minUsableTick) {
            minTick = minUsableTick;
        } else if (minTick > maxUsableTick - length * tickSpacing) {
            minTick = maxUsableTick - length * tickSpacing;
        }
    }
}
