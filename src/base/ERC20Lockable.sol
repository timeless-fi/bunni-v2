// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.4;

import {LibMulticaller} from "multicaller/LibMulticaller.sol";

import "./Constants.sol";
import {ERC20} from "./ERC20.sol";
import {IERC20Lockable} from "../interfaces/IERC20Lockable.sol";
import {IERC20Unlocker} from "../interfaces/IERC20Unlocker.sol";

/// @title ERC20Lockable
/// @notice Supports locking accounts which enables transfer-less staking contracts.
/// @dev The most significant bit of the balance storage slot is used to store the locked flag.
/// Thus balances can only go up to 2^255 - 1.
abstract contract ERC20Lockable is ERC20, IERC20Lockable {
    /// -----------------------------------------------------------------------
    /// Errors
    /// -----------------------------------------------------------------------

    /// @dev Error when the balance overflows 255 bits.
    error BalanceOverflow();

    /// -----------------------------------------------------------------------
    /// Constants
    /// -----------------------------------------------------------------------

    /// @dev Mask for extracting the locked flag from balance slot. Bit 0.
    bytes32 internal constant _LOCKED_MASK = 0x8000000000000000000000000000000000000000000000000000000000000000;

    /// @dev Mask for extracting balance from balance slot. Bits [1, 255].
    bytes32 internal constant _BALANCE_MASK = 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

    /// @dev Max balance for an account.
    uint256 internal constant _MAX_BALANCE = 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

    /// @dev The size of a user's balance in bits.
    uint256 internal constant _BALANCE_SIZE = 255;

    /// @dev Mask for address vars, used for cleaning upper bits via AND.
    bytes32 internal constant _ADDRESS_MASK = 0x000000000000000000000000ffffffffffffffffffffffffffffffffffffffff;

    /// -----------------------------------------------------------------------
    /// Storage
    /// -----------------------------------------------------------------------

    /// @dev The unlocker slot of `account` is given by:
    /// ```
    ///     mstore(0x0c, _UNLOCKER_SLOT_SEED)
    ///     mstore(0x00, account)
    ///     let unlockerSlot := keccak256(0x0c, 0x20)
    /// ```
    uint256 internal constant _UNLOCKER_SLOT_SEED = 0x1816035a;

    /// -----------------------------------------------------------------------
    /// IERC20Lockable functions
    /// -----------------------------------------------------------------------

    /// @inheritdoc IERC20Lockable
    function lock(IERC20Unlocker unlocker, bytes calldata data) external override {
        address account = LibMulticaller.senderOrSigner();
        uint256 accountBalance;

        /// @solidity memory-safe-assembly
        assembly {
            /// -----------------------------------------------------------------------
            /// Validation
            /// -----------------------------------------------------------------------

            // clean narrow vars
            unlocker := and(unlocker, _ADDRESS_MASK)

            // load balance slot
            mstore(0x0c, _BALANCE_SLOT_SEED)
            mstore(0x00, account)
            let balanceSlot := keccak256(0x0c, 0x20)
            let balanceSlotValue := sload(balanceSlot)
            accountBalance := and(balanceSlotValue, _BALANCE_MASK)

            // ensure account is not already locked
            if and(balanceSlotValue, _LOCKED_MASK) {
                mstore(0x00, 0x5f0ccd7c) // `AlreadyLocked()`.
                revert(0x1c, 0x04)
            }

            /// -----------------------------------------------------------------------
            /// Storage updates
            /// -----------------------------------------------------------------------

            // set account as locked
            sstore(balanceSlot, or(balanceSlotValue, _LOCKED_MASK))

            // update unlocker
            mstore(0x0c, _UNLOCKER_SLOT_SEED)
            mstore(0x00, account)
            let unlockerSlot := keccak256(0x0c, 0x20)
            sstore(unlockerSlot, unlocker)
        }

        /// -----------------------------------------------------------------------
        /// External calls
        /// -----------------------------------------------------------------------

        unlocker.lockCallback(account, accountBalance, data);

        emit Lock(account, unlocker);
    }

    /// @inheritdoc IERC20Lockable
    function unlock(address account) external override {
        IERC20Unlocker unlocker;

        /// @solidity memory-safe-assembly
        assembly {
            /// -----------------------------------------------------------------------
            /// Validation
            /// -----------------------------------------------------------------------

            // clean narrow vars
            account := and(account, _ADDRESS_MASK)

            // load balance slot
            mstore(0x0c, _BALANCE_SLOT_SEED)
            mstore(0x00, account)
            let balanceSlot := keccak256(0x0c, 0x20)
            let balanceSlotValue := sload(balanceSlot)

            // ensure account is locked
            if iszero(and(balanceSlotValue, _LOCKED_MASK)) {
                mstore(0x00, 0x5090d6c6) // `AlreadyUnlocked()`.
                revert(0x1c, 0x04)
            }

            // ensure sender is the unlocker
            mstore(0x0c, _UNLOCKER_SLOT_SEED)
            mstore(0x00, account)
            let unlockerSlot := keccak256(0x0c, 0x20)
            unlocker := sload(unlockerSlot)
            if iszero(eq(unlocker, caller())) {
                mstore(0x00, 0x746db0ff) // `NotUnlocker()`.
                revert(0x1c, 0x04)
            }

            /// -----------------------------------------------------------------------
            /// Storage updates
            /// -----------------------------------------------------------------------

            // set account as unlocked
            sstore(balanceSlot, sub(balanceSlotValue, _LOCKED_MASK))
        }

        emit Unlock(account, unlocker);
    }

    /// @inheritdoc IERC20Lockable
    function isLocked(address account) public view override returns (bool locked) {
        /// @solidity memory-safe-assembly
        assembly {
            // clean narrow vars
            account := and(account, _ADDRESS_MASK)

            mstore(0x0c, _BALANCE_SLOT_SEED)
            mstore(0x00, account)
            let balanceSlot := keccak256(0x0c, 0x20)
            let balanceSlotValue := sload(balanceSlot)
            locked := shr(255, and(balanceSlotValue, _LOCKED_MASK))
        }
    }

    /// @inheritdoc IERC20Lockable
    function unlockerOf(address account) public view override returns (IERC20Unlocker unlocker) {
        /// @solidity memory-safe-assembly
        assembly {
            // clean narrow vars
            account := and(account, _ADDRESS_MASK)

            mstore(0x0c, _UNLOCKER_SLOT_SEED)
            mstore(0x00, account)
            let unlockerSlot := keccak256(0x0c, 0x20)
            unlocker := sload(unlockerSlot)
        }
    }

    /// -----------------------------------------------------------------------
    /// ERC20 overrides
    /// -----------------------------------------------------------------------

    /// @inheritdoc ERC20
    function balanceOf(address owner) public view virtual override returns (uint256 result) {
        /// @solidity memory-safe-assembly
        assembly {
            // clean narrow vars
            owner := and(owner, _ADDRESS_MASK)

            mstore(0x0c, _BALANCE_SLOT_SEED)
            mstore(0x00, owner)
            result := sload(keccak256(0x0c, 0x20))
            result := and(result, _BALANCE_MASK)
        }
    }

    /// @inheritdoc ERC20
    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        address msgSender = LibMulticaller.senderOrSigner();
        /// @solidity memory-safe-assembly
        assembly {
            // clean narrow vars
            spender := and(spender, _ADDRESS_MASK)

            // Compute the allowance slot and store the amount.
            mstore(0x20, spender)
            mstore(0x0c, _ALLOWANCE_SLOT_SEED)
            mstore(0x00, msgSender)
            sstore(keccak256(0x0c, 0x34), amount)
            // Emit the {Approval} event.
            mstore(0x00, amount)
            log3(0x00, 0x20, _APPROVAL_EVENT_SIGNATURE, msgSender, shr(96, mload(0x2c)))
        }
        return true;
    }

    /// @inheritdoc ERC20
    /// @dev Uses most significant bit of balance slot for lock flag.
    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        address msgSender = LibMulticaller.senderOrSigner();
        bool toLocked;

        _beforeTokenTransfer(msgSender, to, amount);
        /// @solidity memory-safe-assembly
        assembly {
            // clean narrow vars
            to := and(to, _ADDRESS_MASK)

            // Compute the balance slot and load its value.
            mstore(0x0c, _BALANCE_SLOT_SEED)
            mstore(0x00, msgSender)
            let fromBalanceSlot := keccak256(0x0c, 0x20)
            let fromBalance := sload(fromBalanceSlot)
            // Revert if the sender is locked.
            if and(fromBalance, _LOCKED_MASK) {
                mstore(0x00, 0x6315bfbb) // `AccountLocked()`.
                revert(0x1c, 0x04)
            }
            fromBalance := and(fromBalance, _BALANCE_MASK)
            // Revert if insufficient balance.
            if gt(amount, fromBalance) {
                mstore(0x00, 0xf4d678b8) // `InsufficientBalance()`.
                revert(0x1c, 0x04)
            }
            // Subtract and store the updated balance.
            // We know `from` is not locked so no need to store the flag.
            sstore(fromBalanceSlot, sub(fromBalance, amount))
            // Compute the balance slot of `to`.
            mstore(0x00, to)
            let toBalanceSlot := keccak256(0x0c, 0x20)
            // Add and store the updated balance of `to`.
            let toBalance := sload(toBalanceSlot)
            toLocked := and(toBalance, _LOCKED_MASK)
            toBalance := add(and(toBalance, _BALANCE_MASK), amount)
            // Revert if updated balance overflows 255 bits
            if gt(toBalance, _MAX_BALANCE) {
                mstore(0x00, 0x89560ca1) // `BalanceOverflow()`.
                revert(0x1c, 0x04)
            }
            sstore(toBalanceSlot, or(toLocked, toBalance))
            // Shift `toLocked` to fit into a bool.
            toLocked := shr(255, toLocked)
            // Emit the {Transfer} event.
            mstore(0x20, amount)
            log3(0x20, 0x20, _TRANSFER_EVENT_SIGNATURE, msgSender, to)
        }

        // Unlocker callback if `to` is locked.
        if (toLocked) {
            IERC20Unlocker unlocker = unlockerOf(to);
            unlocker.lockedUserReceiveCallback(to, amount);
        }

        // After token transfer hook
        // Must be called after the unlocker callback to prevent reentrancy
        _afterTokenTransfer(msgSender, to, amount);

        return true;
    }

    /// @inheritdoc ERC20
    /// @dev Uses most significant bit of balance slot for lock flag.
    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
        address msgSender = LibMulticaller.senderOrSigner();
        bool toLocked;

        _beforeTokenTransfer(from, to, amount);
        /// @solidity memory-safe-assembly
        assembly {
            // clean narrow vars
            from := and(from, _ADDRESS_MASK)
            to := and(to, _ADDRESS_MASK)

            let from_ := shl(96, from)
            let to_ := shl(96, to)
            // Compute the allowance slot and load its value.
            mstore(0x20, msgSender)
            mstore(0x0c, or(from_, _ALLOWANCE_SLOT_SEED))
            let allowanceSlot := keccak256(0x0c, 0x34)
            let allowance_ := sload(allowanceSlot)
            // If the allowance is not the maximum uint256 value.
            if add(allowance_, 1) {
                // Revert if the amount to be transferred exceeds the allowance.
                if gt(amount, allowance_) {
                    mstore(0x00, 0x13be252b) // `InsufficientAllowance()`.
                    revert(0x1c, 0x04)
                }
                // Subtract and store the updated allowance.
                sstore(allowanceSlot, sub(allowance_, amount))
            }
            // Compute the balance slot and load its value.
            mstore(0x0c, or(from_, _BALANCE_SLOT_SEED))
            let fromBalanceSlot := keccak256(0x0c, 0x20)
            let fromBalance := sload(fromBalanceSlot)
            // Revert if `from` is locked.
            if and(fromBalance, _LOCKED_MASK) {
                mstore(0x00, 0x6315bfbb) // `AccountLocked()`.
                revert(0x1c, 0x04)
            }
            fromBalance := and(fromBalance, _BALANCE_MASK)
            // Revert if insufficient balance.
            if gt(amount, fromBalance) {
                mstore(0x00, 0xf4d678b8) // `InsufficientBalance()`.
                revert(0x1c, 0x04)
            }
            // Subtract and store the updated balance.
            // We know `from` is not locked so no need to store the flag.
            sstore(fromBalanceSlot, sub(fromBalance, amount))
            // Compute the balance slot of `to`.
            mstore(0x00, to)
            let toBalanceSlot := keccak256(0x0c, 0x20)
            // Add and store the updated balance of `to`.
            let toBalance := sload(toBalanceSlot)
            toLocked := and(toBalance, _LOCKED_MASK)
            toBalance := add(and(toBalance, _BALANCE_MASK), amount)
            // Revert if updated balance overflows 255 bits
            if gt(toBalance, _MAX_BALANCE) {
                mstore(0x00, 0x89560ca1) // `BalanceOverflow()`.
                revert(0x1c, 0x04)
            }
            sstore(toBalanceSlot, or(toLocked, toBalance))
            // Shift `toLocked` to fit into a bool.
            toLocked := shr(255, toLocked)
            // Emit the {Transfer} event.
            mstore(0x20, amount)
            log3(0x20, 0x20, _TRANSFER_EVENT_SIGNATURE, from, to)
        }

        // Unlocker callback if `to` is locked.
        if (toLocked) {
            IERC20Unlocker unlocker = unlockerOf(to);
            unlocker.lockedUserReceiveCallback(to, amount);
        }

        // After token transfer hook
        // Must be called after the unlocker callback to prevent reentrancy
        _afterTokenTransfer(from, to, amount);

        return true;
    }

    /// @inheritdoc ERC20
    /// @dev Uses most significant bit of balance slot for lock flag.
    function _mint(address to, uint256 amount) internal virtual override {
        bool toLocked;

        _beforeTokenTransfer(address(0), to, amount);
        /// @solidity memory-safe-assembly
        assembly {
            // clean narrow vars
            to := and(to, _ADDRESS_MASK)

            let to_ := shl(96, to)

            let totalSupplyBefore := sload(_TOTAL_SUPPLY_SLOT)
            let totalSupplyAfter := add(totalSupplyBefore, amount)
            // Revert if the total supply overflows.
            if lt(totalSupplyAfter, totalSupplyBefore) {
                mstore(0x00, 0xe5cfe957) // `TotalSupplyOverflow()`.
                revert(0x1c, 0x04)
            }
            // Store the updated total supply.
            sstore(_TOTAL_SUPPLY_SLOT, totalSupplyAfter)
            // Compute the balance slot and load its value.
            mstore(0x0c, or(to_, _BALANCE_SLOT_SEED))
            let toBalanceSlot := keccak256(0x0c, 0x20)
            // Add and store the updated balance.
            let toBalance := sload(toBalanceSlot)
            toLocked := and(toBalance, _LOCKED_MASK)
            toBalance := add(and(toBalance, _BALANCE_MASK), amount)
            // Revert if updated balance overflows 255 bits
            if gt(toBalance, _MAX_BALANCE) {
                mstore(0x00, 0x89560ca1) // `BalanceOverflow()`.
                revert(0x1c, 0x04)
            }
            sstore(toBalanceSlot, or(toLocked, toBalance))
            // Shift `toLocked` to fit into a bool.
            toLocked := shr(255, toLocked)
            // Emit the {Transfer} event.
            mstore(0x20, amount)
            log3(0x20, 0x20, _TRANSFER_EVENT_SIGNATURE, 0, to)
        }

        // Unlocker callback if `to` is locked.
        if (toLocked) {
            IERC20Unlocker unlocker = unlockerOf(to);
            unlocker.lockedUserReceiveCallback(to, amount);
        }

        // After token transfer hook
        // Must be called after the unlocker callback to prevent reentrancy
        _afterTokenTransfer(address(0), to, amount);
    }

    /// @dev Burns `amount` tokens from `from`, reducing the total supply.
    ///
    /// Emits a {Transfer} event.
    function _burn(address from, uint256 amount) internal virtual override {
        _beforeTokenTransfer(from, address(0), amount);
        /// @solidity memory-safe-assembly
        assembly {
            // clean narrow vars
            from := and(from, _ADDRESS_MASK)

            let from_ := shl(96, from)

            // Compute the balance slot and load its value.
            mstore(0x0c, or(from_, _BALANCE_SLOT_SEED))
            let fromBalanceSlot := keccak256(0x0c, 0x20)
            let fromBalance := sload(fromBalanceSlot)
            // Revert if `from` is locked.
            if and(fromBalance, _LOCKED_MASK) {
                mstore(0x00, 0x6315bfbb) // `AccountLocked()`.
                revert(0x1c, 0x04)
            }
            fromBalance := and(fromBalance, _BALANCE_MASK)
            // Revert if insufficient balance.
            if gt(amount, fromBalance) {
                mstore(0x00, 0xf4d678b8) // `InsufficientBalance()`.
                revert(0x1c, 0x04)
            }
            // Subtract and store the updated balance.
            // We know `from` is not locked so no need to store the flag.
            sstore(fromBalanceSlot, sub(fromBalance, amount))
            // Subtract and store the updated total supply.
            sstore(_TOTAL_SUPPLY_SLOT, sub(sload(_TOTAL_SUPPLY_SLOT), amount))
            // Emit the {Transfer} event.
            mstore(0x00, amount)
            log3(0x00, 0x20, _TRANSFER_EVENT_SIGNATURE, from, 0)
        }
        _afterTokenTransfer(from, address(0), amount);
    }

    /// @dev Moves `amount` of tokens from `from` to `to`.
    function _transfer(address from, address to, uint256 amount) internal virtual override {
        bool toLocked;

        _beforeTokenTransfer(from, to, amount);
        /// @solidity memory-safe-assembly
        assembly {
            // clean narrow vars
            from := and(from, _ADDRESS_MASK)
            to := and(to, _ADDRESS_MASK)

            let from_ := shl(96, from)
            let to_ := shl(96, to)

            // Compute the balance slot and load its value.
            mstore(0x0c, or(from_, _BALANCE_SLOT_SEED))
            let fromBalanceSlot := keccak256(0x0c, 0x20)
            let fromBalance := sload(fromBalanceSlot)
            // Revert if `from` is locked.
            if and(fromBalance, _LOCKED_MASK) {
                mstore(0x00, 0x6315bfbb) // `AccountLocked()`.
                revert(0x1c, 0x04)
            }
            fromBalance := and(fromBalance, _BALANCE_MASK)
            // Revert if insufficient balance.
            if gt(amount, fromBalance) {
                mstore(0x00, 0xf4d678b8) // `InsufficientBalance()`.
                revert(0x1c, 0x04)
            }
            // Subtract and store the updated balance.
            // We know `from` is not locked so no need to store the flag.
            sstore(fromBalanceSlot, sub(fromBalance, amount))
            // Compute the balance slot of `to`.
            mstore(0x00, to)
            let toBalanceSlot := keccak256(0x0c, 0x20)
            let toBalance := sload(toBalanceSlot)
            toLocked := and(toBalance, _LOCKED_MASK)
            // Add and store the updated balance of `to`.
            // Revert if updated balance overflows 255 bits
            toBalance := add(and(toBalance, _BALANCE_MASK), amount)
            if gt(toBalance, _MAX_BALANCE) {
                mstore(0x00, 0x89560ca1) // `BalanceOverflow()`.
                revert(0x1c, 0x04)
            }
            sstore(toBalanceSlot, or(toLocked, toBalance))
            // Shift `toLocked` to fit into a bool.
            toLocked := shr(255, toLocked)
            // Emit the {Transfer} event.
            mstore(0x20, amount)
            log3(0x20, 0x20, _TRANSFER_EVENT_SIGNATURE, from, to)
        }

        // Unlocker callback if `to` is locked.
        if (toLocked) {
            IERC20Unlocker unlocker = unlockerOf(to);
            unlocker.lockedUserReceiveCallback(to, amount);
        }

        // After token transfer hook
        // Must be called after the unlocker callback to prevent reentrancy
        _afterTokenTransfer(from, to, amount);
    }
}
