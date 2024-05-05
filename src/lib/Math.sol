// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.19;

import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import "../base/Constants.sol";

using FixedPointMathLib for int256;
using FixedPointMathLib for uint256;

/// @dev modified from solady
function dist(uint256 x, uint256 y) pure returns (uint256 z) {
    /// @solidity memory-safe-assembly
    assembly {
        z := xor(mul(xor(sub(y, x), sub(x, y)), gt(x, y)), sub(y, x))
    }
}

/// @dev modified from solady
function absDiff(uint256 x, uint256 y) pure returns (bool positive, uint256 diff) {
    /// @solidity memory-safe-assembly
    assembly {
        positive := gt(x, y)
        diff := xor(mul(xor(sub(y, x), sub(x, y)), gt(x, y)), sub(y, x))
    }
}

function roundTick(int24 currentTick, int24 tickSpacing) pure returns (int24 roundedTick, int24 nextRoundedTick) {
    int24 compressed = currentTick / tickSpacing;
    if (currentTick < 0 && currentTick % tickSpacing != 0) compressed--; // round towards negative infinity
    roundedTick = compressed * tickSpacing;
    nextRoundedTick = roundedTick + tickSpacing;
}

function roundTickSingle(int24 currentTick, int24 tickSpacing) pure returns (int24 roundedTick) {
    int24 compressed = currentTick / tickSpacing;
    if (currentTick < 0 && currentTick % tickSpacing != 0) compressed--; // round towards negative infinity
    roundedTick = compressed * tickSpacing;
}

function boundTick(int24 tick, int24 tickSpacing) pure returns (int24 boundedTick) {
    (int24 minTick, int24 maxTick) = (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
    return int24(FixedPointMathLib.clamp(tick, minTick, maxTick));
}

function weightedSum(uint256 value0, uint256 weight0, uint256 value1, uint256 weight1) pure returns (uint256) {
    return (value0 * weight0 + value1 * weight1) / (weight0 + weight1);
}

function xWadToRoundedTick(int256 xWad, int24 mu, int24 tickSpacing, bool roundUp) pure returns (int24) {
    int24 x = SafeCastLib.toInt24(xWad / int256(WAD));
    if (roundUp) {
        if (xWad > 0 && xWad % int256(WAD) != 0) x++; // round towards positive infinity
    } else {
        if (xWad < 0 && xWad % int256(WAD) != 0) x--; // round towards negative infinity
    }
    return x * tickSpacing + mu;
}

function percentDelta(uint256 a, uint256 b) pure returns (uint256) {
    uint256 absDelta = dist(a, b);
    return FixedPointMathLib.divWad(absDelta, b);
}

function computeSurgeFee(uint32 lastSurgeTimestamp, uint24 surgeFee, uint16 surgeFeeHalfLife)
    view
    returns (uint24 fee)
{
    // compute surge fee
    // surge fee gets applied after the LDF shifts (if it's dynamic)
    unchecked {
        uint256 timeSinceLastSurge = block.timestamp - lastSurgeTimestamp;
        fee = uint24(
            uint256(surgeFee).mulWadUp(
                uint256((-int256(timeSinceLastSurge.mulDiv(LN2_WAD, surgeFeeHalfLife))).expWad())
            )
        );
    }
}
