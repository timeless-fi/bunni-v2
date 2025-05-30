// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IBunniHook} from "../interfaces/IBunniHook.sol";

/// @notice A helper library to provide state getters that use extsload
/// @dev Use `forge inspect [ContractName] storageLayout` to get the slot values
library BunniStateLibrary {
    bytes32 public constant VAULT_SHARE_PRICES_SLOT = bytes32(uint256(11));
    bytes32 public constant HOOK_FEE_SLOT = bytes32(uint256(14));

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

    function getReferralRewardModifier(IBunniHook hook) internal view returns (uint32 referralRewardModifier) {
        bytes32 data = hook.extsload(HOOK_FEE_SLOT);
        assembly ("memory-safe") {
            referralRewardModifier := and(0xffffffff, shr(192, data))
        }
    }

    function _getVaultSharePricesSlot(PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(PoolId.unwrap(poolId), VAULT_SHARE_PRICES_SLOT));
    }
}
