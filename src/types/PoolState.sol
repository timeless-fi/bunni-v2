// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import {PoolId, PoolKey, Currency} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {SSTORE2} from "solady/utils/SSTORE2.sol";
import {ERC4626} from "solady/tokens/ERC4626.sol";

import "../base/Errors.sol";
import {HubStorage} from "../base/SharedStructs.sol";
import {IBunniToken} from "../interfaces/IBunniToken.sol";
import {ILiquidityDensityFunction} from "../interfaces/ILiquidityDensityFunction.sol";

using SSTORE2 for address;

/// @notice The state of a Bunni pool
/// @member liquidityDensityFunction The LDF that dictates how liquidity is distributed
/// @member bunniToken The BunniToken for this pool
/// @member twapSecondsAgo The time window for the TWAP used by the LDF. Set to 0 if the LDF does not use the TWAP.
/// @member ldfParams The parameters for the LDF
/// @member hookParams The hook parameters for the pool
/// @member vault0 The ERC4626 vault used for currency0
/// @member vault1 The ERC4626 vault used for currency1
/// @member statefulLdf Whether the LDF is stateful. Each stateful LDF is given a bytes32 state that's updated after each query() call.
/// @member minRawTokenRatio0 The minimum (rawBalance / balance) ratio for currency0
/// @member targetRawTokenRatio0 The target (rawBalance / balance) ratio for currency0
/// @member maxRawTokenRatio0 The maximum (rawBalance / balance) ratio for currency0
/// @member minRawTokenRatio1 The minimum (rawBalance / balance) ratio for currency1
/// @member targetRawTokenRatio1 The target (rawBalance / balance) ratio for currency1
/// @member maxRawTokenRatio1 The maximum (rawBalance / balance) ratio for currency1
/// @member amAmmEnabled Whether the am-AMM is enabled for this pool. Can be overriden by governance.
/// @member rawBalance0 The raw token balance of currency0. Raw just means it's not stored in a ERC4626 vault.
/// @member rawBalance1 The raw token balance of currency1. Raw just means it's not stored in a ERC4626 vault.
/// @member reserve0 The vault share tokens owned in vault0
/// @member reserve1 The vault share tokens owned in vault1
struct PoolState {
    ILiquidityDensityFunction liquidityDensityFunction;
    IBunniToken bunniToken;
    uint24 twapSecondsAgo;
    bytes32 ldfParams;
    bytes32 hookParams;
    ERC4626 vault0;
    ERC4626 vault1;
    bool statefulLdf;
    uint24 minRawTokenRatio0;
    uint24 targetRawTokenRatio0;
    uint24 maxRawTokenRatio0;
    uint24 minRawTokenRatio1;
    uint24 targetRawTokenRatio1;
    uint24 maxRawTokenRatio1;
    bool amAmmEnabled;
    uint256 rawBalance0;
    uint256 rawBalance1;
    uint256 reserve0;
    uint256 reserve1;
}

/// @notice The raw state of a given pool
/// @dev Since a pool's parameters are immutable, we use SSTORE2 to store them cheaply and store the pointer here.
/// @member immutableParamsPointer The SSTORE2 pointer to the immutable parameters of the pool
/// @member rawBalance0 The raw token balance of currency0. Raw just means it's not stored in a ERC4626 vault.
/// @member rawBalance1 The raw token balance of currency1. Raw just means it's not stored in a ERC4626 vault.
struct RawPoolState {
    address immutableParamsPointer;
    uint256 rawBalance0;
    uint256 rawBalance1;
}

function getPoolParams(address ptr) view returns (PoolState memory state) {
    // read params via SSLOAD2
    bytes memory immutableParams = ptr.read();
    {
        ILiquidityDensityFunction liquidityDensityFunction;
        assembly ("memory-safe") {
            liquidityDensityFunction := shr(96, mload(add(immutableParams, 32)))
        }
        state.liquidityDensityFunction = liquidityDensityFunction;
    }

    {
        IBunniToken bunniToken;
        assembly ("memory-safe") {
            bunniToken := shr(96, mload(add(immutableParams, 52)))
        }
        state.bunniToken = bunniToken;
    }

    {
        uint24 twapSecondsAgo;
        assembly ("memory-safe") {
            twapSecondsAgo := shr(232, mload(add(immutableParams, 72)))
        }
        state.twapSecondsAgo = twapSecondsAgo;
    }

    {
        bytes32 ldfParams;
        assembly ("memory-safe") {
            ldfParams := mload(add(immutableParams, 75))
        }
        state.ldfParams = ldfParams;
    }

    {
        bytes32 hookParams_;
        assembly ("memory-safe") {
            hookParams_ := mload(add(immutableParams, 107))
        }
        state.hookParams = hookParams_;
    }

    {
        ERC4626 vault0;
        assembly ("memory-safe") {
            vault0 := shr(96, mload(add(immutableParams, 139)))
        }
        state.vault0 = vault0;
    }

    {
        ERC4626 vault1;
        assembly ("memory-safe") {
            vault1 := shr(96, mload(add(immutableParams, 159)))
        }
        state.vault1 = vault1;
    }

    {
        bool statefulLdf;
        assembly ("memory-safe") {
            statefulLdf := shr(248, mload(add(immutableParams, 179)))
        }
        state.statefulLdf = statefulLdf;
    }

    {
        uint24 minRawTokenRatio0;
        assembly ("memory-safe") {
            minRawTokenRatio0 := shr(232, mload(add(immutableParams, 180)))
        }
        state.minRawTokenRatio0 = minRawTokenRatio0;
    }

    {
        uint24 targetRawTokenRatio0;
        assembly ("memory-safe") {
            targetRawTokenRatio0 := shr(232, mload(add(immutableParams, 183)))
        }
        state.targetRawTokenRatio0 = targetRawTokenRatio0;
    }

    {
        uint24 maxRawTokenRatio0;
        assembly ("memory-safe") {
            maxRawTokenRatio0 := shr(232, mload(add(immutableParams, 186)))
        }
        state.maxRawTokenRatio0 = maxRawTokenRatio0;
    }

    {
        uint24 minRawTokenRatio1;
        assembly ("memory-safe") {
            minRawTokenRatio1 := shr(232, mload(add(immutableParams, 189)))
        }
        state.minRawTokenRatio1 = minRawTokenRatio1;
    }

    {
        uint24 targetRawTokenRatio1;
        assembly ("memory-safe") {
            targetRawTokenRatio1 := shr(232, mload(add(immutableParams, 192)))
        }
        state.targetRawTokenRatio1 = targetRawTokenRatio1;
    }

    {
        uint24 maxRawTokenRatio1;
        assembly ("memory-safe") {
            maxRawTokenRatio1 := shr(232, mload(add(immutableParams, 195)))
        }
        state.maxRawTokenRatio1 = maxRawTokenRatio1;
    }
}

function getPoolState(HubStorage storage s, PoolId poolId) view returns (PoolState memory state) {
    RawPoolState memory rawState = s.poolState[poolId];
    if (rawState.immutableParamsPointer == address(0)) revert BunniHub__BunniTokenNotInitialized();

    state = getPoolParams(rawState.immutableParamsPointer);
    state.rawBalance0 = rawState.rawBalance0;
    state.rawBalance1 = rawState.rawBalance1;
    state.reserve0 = address(state.vault0) != address(0) ? s.reserve0[poolId] : 0;
    state.reserve1 = address(state.vault1) != address(0) ? s.reserve1[poolId] : 0;
}
