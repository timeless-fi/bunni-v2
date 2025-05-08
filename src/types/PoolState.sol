// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {PoolId, PoolKey, Currency} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {SSTORE2} from "solady/utils/SSTORE2.sol";
import {ERC4626} from "solady/tokens/ERC4626.sol";

import "./LDFType.sol";
import "./IdleBalance.sol";
import "../base/Errors.sol";
import {IHooklet} from "../interfaces/IHooklet.sol";
import {HubStorage} from "../base/SharedStructs.sol";
import {IBunniToken} from "../interfaces/IBunniToken.sol";
import {ILiquidityDensityFunction} from "../interfaces/ILiquidityDensityFunction.sol";

using SSTORE2 for address;

/// @notice The state of a Bunni pool
/// @member liquidityDensityFunction The LDF that dictates how liquidity is distributed
/// @member bunniToken The BunniToken for this pool
/// @member hooklet The hooklet for this pool. Set to address(0) if the pool does not have a hooklet.
/// @member twapSecondsAgo The time window for the TWAP used by the LDF. Set to 0 if the LDF does not use the TWAP.
/// @member ldfParams The parameters for the LDF
/// @member hookParams The hook parameters for the pool
/// @member vault0 The ERC4626 vault used for currency0
/// @member vault1 The ERC4626 vault used for currency1
/// @member ldfType The type of LDF. See LDFType.sol for details.
/// @member minRawTokenRatio0 The minimum (rawBalance / balance) ratio for currency0
/// @member targetRawTokenRatio0 The target (rawBalance / balance) ratio for currency0
/// @member maxRawTokenRatio0 The maximum (rawBalance / balance) ratio for currency0
/// @member minRawTokenRatio1 The minimum (rawBalance / balance) ratio for currency1
/// @member targetRawTokenRatio1 The target (rawBalance / balance) ratio for currency1
/// @member maxRawTokenRatio1 The maximum (rawBalance / balance) ratio for currency1
/// @member currency0Decimals The decimals of currency0
/// @member currency1Decimals The decimals of currency1
/// @member vault0Decimals The decimals of vault0
/// @member vault1Decimals The decimals of vault1
/// @member rawBalance0 The raw token balance of currency0. Raw just means it's not stored in a ERC4626 vault.
/// @member rawBalance1 The raw token balance of currency1. Raw just means it's not stored in a ERC4626 vault.
/// @member reserve0 The vault share tokens owned in vault0
/// @member reserve1 The vault share tokens owned in vault1
/// @member idleBalance The balance of the token that's in excess. Used when computing the total liquidity.
struct PoolState {
    ILiquidityDensityFunction liquidityDensityFunction;
    IBunniToken bunniToken;
    IHooklet hooklet;
    uint24 twapSecondsAgo;
    bytes32 ldfParams;
    bytes hookParams;
    ERC4626 vault0;
    ERC4626 vault1;
    LDFType ldfType;
    uint24 minRawTokenRatio0;
    uint24 targetRawTokenRatio0;
    uint24 maxRawTokenRatio0;
    uint24 minRawTokenRatio1;
    uint24 targetRawTokenRatio1;
    uint24 maxRawTokenRatio1;
    uint8 currency0Decimals;
    uint8 currency1Decimals;
    uint8 vault0Decimals;
    uint8 vault1Decimals;
    uint256 rawBalance0;
    uint256 rawBalance1;
    uint256 reserve0;
    uint256 reserve1;
    IdleBalance idleBalance;
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
        /// @solidity memory-safe-assembly
        assembly {
            liquidityDensityFunction := shr(96, mload(add(immutableParams, 32)))
        }
        state.liquidityDensityFunction = liquidityDensityFunction;
    }

    {
        IBunniToken bunniToken;
        /// @solidity memory-safe-assembly
        assembly {
            bunniToken := shr(96, mload(add(immutableParams, 52)))
        }
        state.bunniToken = bunniToken;
    }

    {
        uint24 twapSecondsAgo;
        /// @solidity memory-safe-assembly
        assembly {
            twapSecondsAgo := shr(232, mload(add(immutableParams, 72)))
        }
        state.twapSecondsAgo = twapSecondsAgo;
    }

    {
        bytes32 ldfParams;
        /// @solidity memory-safe-assembly
        assembly {
            ldfParams := mload(add(immutableParams, 75))
        }
        state.ldfParams = ldfParams;
    }

    {
        ERC4626 vault0;
        /// @solidity memory-safe-assembly
        assembly {
            vault0 := shr(96, mload(add(immutableParams, 107)))
        }
        state.vault0 = vault0;
    }

    {
        ERC4626 vault1;
        /// @solidity memory-safe-assembly
        assembly {
            vault1 := shr(96, mload(add(immutableParams, 127)))
        }
        state.vault1 = vault1;
    }

    {
        LDFType ldfType;
        /// @solidity memory-safe-assembly
        assembly {
            ldfType := shr(248, mload(add(immutableParams, 147)))
        }
        state.ldfType = ldfType;
    }

    {
        uint24 minRawTokenRatio0;
        /// @solidity memory-safe-assembly
        assembly {
            minRawTokenRatio0 := shr(232, mload(add(immutableParams, 148)))
        }
        state.minRawTokenRatio0 = minRawTokenRatio0;
    }

    {
        uint24 targetRawTokenRatio0;
        /// @solidity memory-safe-assembly
        assembly {
            targetRawTokenRatio0 := shr(232, mload(add(immutableParams, 151)))
        }
        state.targetRawTokenRatio0 = targetRawTokenRatio0;
    }

    {
        uint24 maxRawTokenRatio0;
        /// @solidity memory-safe-assembly
        assembly {
            maxRawTokenRatio0 := shr(232, mload(add(immutableParams, 154)))
        }
        state.maxRawTokenRatio0 = maxRawTokenRatio0;
    }

    {
        uint24 minRawTokenRatio1;
        /// @solidity memory-safe-assembly
        assembly {
            minRawTokenRatio1 := shr(232, mload(add(immutableParams, 157)))
        }
        state.minRawTokenRatio1 = minRawTokenRatio1;
    }

    {
        uint24 targetRawTokenRatio1;
        /// @solidity memory-safe-assembly
        assembly {
            targetRawTokenRatio1 := shr(232, mload(add(immutableParams, 160)))
        }
        state.targetRawTokenRatio1 = targetRawTokenRatio1;
    }

    {
        uint24 maxRawTokenRatio1;
        /// @solidity memory-safe-assembly
        assembly {
            maxRawTokenRatio1 := shr(232, mload(add(immutableParams, 163)))
        }
        state.maxRawTokenRatio1 = maxRawTokenRatio1;
    }

    {
        IHooklet hooklet;
        /// @solidity memory-safe-assembly
        assembly {
            hooklet := shr(96, mload(add(immutableParams, 166)))
        }
        state.hooklet = hooklet;
    }

    {
        uint8 currency0Decimals;
        /// @solidity memory-safe-assembly
        assembly {
            currency0Decimals := shr(248, mload(add(immutableParams, 186)))
        }
        state.currency0Decimals = currency0Decimals;
    }

    {
        uint8 currency1Decimals;
        /// @solidity memory-safe-assembly
        assembly {
            currency1Decimals := shr(248, mload(add(immutableParams, 187)))
        }
        state.currency1Decimals = currency1Decimals;
    }

    {
        uint8 vault0Decimals;
        /// @solidity memory-safe-assembly
        assembly {
            vault0Decimals := shr(248, mload(add(immutableParams, 188)))
        }
        state.vault0Decimals = vault0Decimals;
    }

    {
        uint8 vault1Decimals;
        /// @solidity memory-safe-assembly
        assembly {
            vault1Decimals := shr(248, mload(add(immutableParams, 189)))
        }
        state.vault1Decimals = vault1Decimals;
    }

    {
        bytes memory hookParams;
        /// @solidity memory-safe-assembly
        assembly {
            let hookParamsLen := shr(240, mload(add(immutableParams, 190))) // uint16
            hookParams := add(immutableParams, 160) // 160 = 190 (hookParamsLen location) + 2 (hookParamsLen is uint16) - 32 (expand hookParamsLen to 32 bytes)
            mstore(hookParams, hookParamsLen) // overwrite length field of `bytes memory hookParams`
        }
        state.hookParams = hookParams;
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

    // idle balance is only needed when the LDF is not static since static LDFs
    // can never become imbalanced
    state.idleBalance = state.ldfType == LDFType.STATIC ? IdleBalanceLibrary.ZERO : s.idleBalance[poolId];
}
