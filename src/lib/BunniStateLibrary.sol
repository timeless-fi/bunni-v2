// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IBunniHook} from "../interfaces/IBunniHook.sol";

/// @notice A helper library to provide state getters that use extsload
/// @dev Use `forge inspect [ContractName] storageLayout` to get the slot values
library BunniStateLibrary {
    bytes32 public constant VAULT_SHARE_PRICES_SLOT = bytes32(uint256(11));
    bytes32 public constant CURATOR_FEES_SLOT = bytes32(uint256(15));
    bytes32 public constant HOOK_FEE_SLOT = bytes32(uint256(16));

    bytes32 public constant UINT120_MASK = 0x0000000000000000000000000000000000ffffffffffffffffffffffffffffff;
    bytes32 public constant ADDRESS_MASK = 0x000000000000000000000000ffffffffffffffffffffffffffffffffffffffff;

    function getVaultSharePricesAtLastSwap(IBunniHook hook, PoolId poolId)
        internal
        view
        returns (bool initialized, uint120 sharePrice0, uint120 sharePrice1)
    {
        bytes32 data = hook.extsload(_getVaultSharePricesSlot(poolId));
        assembly ("memory-safe") {
            // bottom 8 bits of data
            initialized := and(0xff, data)
            // next 120 bits of data
            sharePrice0 := and(UINT120_MASK, shr(8, data))
            // next 120 bits of data
            sharePrice1 := and(UINT120_MASK, shr(128, data))
        }
    }

    function getHookFeeRecipient(IBunniHook hook) internal view returns (address recipient) {
        bytes32 data = hook.extsload(HOOK_FEE_SLOT);
        assembly ("memory-safe") {
            recipient := and(ADDRESS_MASK, data)
        }
    }

    function getHookFeeModifier(IBunniHook hook) internal view returns (uint32 hookFeeModifier) {
        bytes32 data = hook.extsload(HOOK_FEE_SLOT);
        assembly ("memory-safe") {
            hookFeeModifier := and(0xffffffff, shr(160, data))
        }
    }

    function getCuratorFees(IBunniHook hook, PoolId poolId)
        internal
        view
        returns (uint16 feeRate, uint120 accruedFee0, uint120 accruedFee1)
    {
        bytes32 data = hook.extsload(_getCuratorFeesSlot(poolId));
        assembly ("memory-safe") {
            // bottom 16 bits of data
            feeRate := and(0xffff, data)
            // next 120 bits of data
            accruedFee0 := and(UINT120_MASK, shr(16, data))
            // next 120 bits of data
            accruedFee1 := and(UINT120_MASK, shr(136, data))
        }
    }

    function _getVaultSharePricesSlot(PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encode(PoolId.unwrap(poolId), VAULT_SHARE_PRICES_SLOT));
    }

    function _getCuratorFeesSlot(PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encode(PoolId.unwrap(poolId), CURATOR_FEES_SLOT));
    }
}
