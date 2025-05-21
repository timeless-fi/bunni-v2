// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IPoolManager, PoolKey} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import "../base/Constants.sol";
import {IHooklet} from "../interfaces/IHooklet.sol";
import {IBunniHub} from "../interfaces/IBunniHub.sol";
import {IBunniToken} from "../interfaces/IBunniToken.sol";

/// @dev Adapted from Uniswap v4's Hooks.sol
library HookletLib {
    using CustomRevert for bytes4;
    using HookletLib for IHooklet;
    using FixedPointMathLib for *;

    uint160 internal constant ALL_FLAGS_MASK = 0xFFF;
    uint160 internal constant BEFORE_TRANSFER_FLAG = 1 << 11;
    uint160 internal constant AFTER_TRANSFER_FLAG = 1 << 10;
    uint160 internal constant BEFORE_INITIALIZE_FLAG = 1 << 9;
    uint160 internal constant AFTER_INITIALIZE_FLAG = 1 << 8;
    uint160 internal constant BEFORE_DEPOSIT_FLAG = 1 << 7;
    uint160 internal constant AFTER_DEPOSIT_FLAG = 1 << 6;
    uint160 internal constant BEFORE_WITHDRAW_FLAG = 1 << 5;
    uint160 internal constant AFTER_WITHDRAW_FLAG = 1 << 4;
    uint160 internal constant BEFORE_SWAP_FLAG = 1 << 3;
    uint160 internal constant BEFORE_SWAP_OVERRIDE_FEE_FLAG = 1 << 2;
    uint160 internal constant BEFORE_SWAP_OVERRIDE_PRICE_FLAG = 1 << 1;
    uint160 internal constant AFTER_SWAP_FLAG = 1;

    error HookletLib__FailedHookletCall();
    error HookletLib__InvalidHookletResponse();

    function callHooklet(IHooklet self, bytes4 selector, bytes memory data) internal returns (bytes memory result) {
        bytes4 decodedSelector;
        assembly ("memory-safe") {
            if iszero(call(gas(), self, 0, add(data, 0x20), mload(data), 0, 0)) {
                if iszero(returndatasize()) {
                    // if the call failed without a revert reason, revert with `HookletLib__FailedHookletCall()`
                    mstore(0, 0x855e32e7)
                    revert(0x1c, 0x04)
                }
                // bubble up revert
                let fmp := mload(0x40)
                returndatacopy(fmp, 0, returndatasize())
                revert(fmp, returndatasize())
            }
            // allocate result byte array from the free memory pointer
            result := mload(0x40)
            // store new free memory pointer at the end of the array padded to 32 bytes
            mstore(0x40, add(result, and(add(returndatasize(), 0x3f), not(0x1f))))
            // store length in memory
            mstore(result, returndatasize())
            // copy return data to result
            returndatacopy(add(result, 0x20), 0, returndatasize())
            // get the selector from the return data
            decodedSelector := mload(add(result, 0x20))
        }
        if (decodedSelector != selector) HookletLib__InvalidHookletResponse.selector.revertWith();
    }

    function staticcallHooklet(IHooklet self, bytes4 selector, bytes memory data)
        internal
        view
        returns (bool success, bytes memory result)
    {
        bytes4 decodedSelector;
        assembly ("memory-safe") {
            switch staticcall(gas(), self, add(data, 0x20), mload(data), 0, 0)
            case 0 {
                // call reverted, set success to false
                success := 0
            }
            default {
                // call succeeded, set success to true
                success := 1
                // allocate result byte array from the free memory pointer
                result := mload(0x40)
                // store new free memory pointer at the end of the array padded to 32 bytes
                mstore(0x40, add(result, and(add(returndatasize(), 0x3f), not(0x1f))))
                // store length in memory
                mstore(result, returndatasize())
                // copy return data to result
                returndatacopy(add(result, 0x20), 0, returndatasize())
                // get the selector from the return data
                decodedSelector := mload(add(result, 0x20))
            }
        }
        if (decodedSelector != selector) return (false, bytes(""));
    }

    modifier noSelfCall(IHooklet self, address sender) {
        if (sender != address(self)) {
            _;
        }
    }

    /// @dev The hasPermission check is done outside of this function in order to avoid unnecessarily constructing `key`
    function hookletBeforeTransfer(
        IHooklet self,
        address sender,
        PoolKey memory key,
        IBunniToken bunniToken,
        address from,
        address to,
        uint256 amount
    ) internal noSelfCall(self, sender) {
        self.callHooklet(
            IHooklet.beforeTransfer.selector,
            abi.encodeCall(IHooklet.beforeTransfer, (sender, key, bunniToken, from, to, amount))
        );
    }

    /// @dev The hasPermission check is done outside of this function in order to avoid unnecessarily constructing `key`
    function hookletAfterTransfer(
        IHooklet self,
        address sender,
        PoolKey memory key,
        IBunniToken bunniToken,
        address from,
        address to,
        uint256 amount
    ) internal noSelfCall(self, sender) {
        self.callHooklet(
            IHooklet.afterTransfer.selector,
            abi.encodeCall(IHooklet.afterTransfer, (sender, key, bunniToken, from, to, amount))
        );
    }

    function hookletBeforeInitialize(IHooklet self, address sender, IBunniHub.DeployBunniTokenParams calldata params)
        internal
        noSelfCall(self, sender)
    {
        if (self.hasPermission(BEFORE_INITIALIZE_FLAG)) {
            self.callHooklet(
                IHooklet.beforeInitialize.selector, abi.encodeCall(IHooklet.beforeInitialize, (sender, params))
            );
        }
    }

    function hookletAfterInitialize(
        IHooklet self,
        address sender,
        IBunniHub.DeployBunniTokenParams calldata params,
        IHooklet.InitializeReturnData memory returnData
    ) internal noSelfCall(self, sender) {
        if (self.hasPermission(AFTER_INITIALIZE_FLAG)) {
            self.callHooklet(
                IHooklet.afterInitialize.selector,
                abi.encodeCall(IHooklet.afterInitialize, (sender, params, returnData))
            );
        }
    }

    function hookletBeforeDeposit(IHooklet self, address sender, IBunniHub.DepositParams calldata params)
        internal
        noSelfCall(self, sender)
    {
        if (self.hasPermission(BEFORE_DEPOSIT_FLAG)) {
            self.callHooklet(IHooklet.beforeDeposit.selector, abi.encodeCall(IHooklet.beforeDeposit, (sender, params)));
        }
    }

    function hookletBeforeDepositView(IHooklet self, address sender, IBunniHub.DepositParams calldata params)
        internal
        view
        noSelfCall(self, sender)
        returns (bool success)
    {
        if (self.hasPermission(BEFORE_DEPOSIT_FLAG)) {
            (success,) = self.staticcallHooklet(
                IHooklet.beforeDepositView.selector, abi.encodeCall(IHooklet.beforeDepositView, (sender, params))
            );
        } else {
            success = true;
        }
    }

    function hookletAfterDeposit(
        IHooklet self,
        address sender,
        IBunniHub.DepositParams calldata params,
        IHooklet.DepositReturnData memory returnData
    ) internal noSelfCall(self, sender) {
        if (self.hasPermission(AFTER_DEPOSIT_FLAG)) {
            self.callHooklet(
                IHooklet.afterDeposit.selector, abi.encodeCall(IHooklet.afterDeposit, (sender, params, returnData))
            );
        }
    }

    function hookletAfterDepositView(
        IHooklet self,
        address sender,
        IBunniHub.DepositParams calldata params,
        IHooklet.DepositReturnData memory returnData
    ) internal view noSelfCall(self, sender) returns (bool success) {
        if (self.hasPermission(AFTER_DEPOSIT_FLAG)) {
            (success,) = self.staticcallHooklet(
                IHooklet.afterDepositView.selector,
                abi.encodeCall(IHooklet.afterDepositView, (sender, params, returnData))
            );
        } else {
            success = true;
        }
    }

    function hookletBeforeWithdraw(IHooklet self, address sender, IBunniHub.WithdrawParams calldata params)
        internal
        noSelfCall(self, sender)
    {
        if (self.hasPermission(BEFORE_WITHDRAW_FLAG)) {
            self.callHooklet(
                IHooklet.beforeWithdraw.selector, abi.encodeCall(IHooklet.beforeWithdraw, (sender, params))
            );
        }
    }

    function hookletBeforeWithdrawView(IHooklet self, address sender, IBunniHub.WithdrawParams calldata params)
        internal
        view
        noSelfCall(self, sender)
        returns (bool success)
    {
        if (self.hasPermission(BEFORE_WITHDRAW_FLAG)) {
            (success,) = self.staticcallHooklet(
                IHooklet.beforeWithdrawView.selector, abi.encodeCall(IHooklet.beforeWithdrawView, (sender, params))
            );
        } else {
            success = true;
        }
    }

    function hookletAfterWithdraw(
        IHooklet self,
        address sender,
        IBunniHub.WithdrawParams calldata params,
        IHooklet.WithdrawReturnData memory returnData
    ) internal noSelfCall(self, sender) {
        if (self.hasPermission(AFTER_WITHDRAW_FLAG)) {
            self.callHooklet(
                IHooklet.afterWithdraw.selector, abi.encodeCall(IHooklet.afterWithdraw, (sender, params, returnData))
            );
        }
    }

    function hookletAfterWithdrawView(
        IHooklet self,
        address sender,
        IBunniHub.WithdrawParams calldata params,
        IHooklet.WithdrawReturnData memory returnData
    ) internal view noSelfCall(self, sender) returns (bool success) {
        if (self.hasPermission(AFTER_WITHDRAW_FLAG)) {
            (success,) = self.staticcallHooklet(
                IHooklet.afterWithdrawView.selector,
                abi.encodeCall(IHooklet.afterWithdrawView, (sender, params, returnData))
            );
        } else {
            success = true;
        }
    }

    function hookletBeforeSwap(
        IHooklet self,
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    )
        internal
        noSelfCall(self, sender)
        returns (bool feeOverridden, uint24 fee, bool priceOverridden, uint160 sqrtPriceX96)
    {
        if (self.hasPermission(BEFORE_SWAP_FLAG)) {
            bytes memory result = self.callHooklet(
                IHooklet.beforeSwap.selector, abi.encodeCall(IHooklet.beforeSwap, (sender, key, params))
            );
            (bool canOverrideFee, bool canOverridePrice) =
                (self.hasPermission(BEFORE_SWAP_OVERRIDE_FEE_FLAG), self.hasPermission(BEFORE_SWAP_OVERRIDE_PRICE_FLAG));
            if (canOverrideFee || canOverridePrice) {
                // parse override data
                // equivalent to the following Solidity code:
                // (,feeOverridden, fee, priceOverridden, sqrtPriceX96) = abi.decode(result, (bytes4, bool, uint24, bool, uint160));
                /// @solidity memory-safe-assembly
                assembly {
                    feeOverridden := mload(add(result, 0x40))
                    fee := mload(add(result, 0x60))
                    priceOverridden := mload(add(result, 0x80))
                    sqrtPriceX96 := mload(add(result, 0xA0))
                }

                // ensure that the hooklet is allowed to override the fee and/or price
                // if the hooklet doesn't have a permission but the override is set, the override is ignored
                feeOverridden = canOverrideFee && feeOverridden;
                priceOverridden = canOverridePrice && priceOverridden;

                // clamp the override values to the valid range
                fee = feeOverridden ? uint24(fee.clamp(0, SWAP_FEE_BASE)) : 0;
                sqrtPriceX96 =
                    priceOverridden ? uint160(sqrtPriceX96.clamp(TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE)) : 0;
            }
        }
    }

    function hookletBeforeSwapView(
        IHooklet self,
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    )
        internal
        view
        noSelfCall(self, sender)
        returns (bool success, bool feeOverridden, uint24 fee, bool priceOverridden, uint160 sqrtPriceX96)
    {
        if (
            self.hasPermission(BEFORE_SWAP_FLAG)
                && (
                    self.hasPermission(BEFORE_SWAP_OVERRIDE_FEE_FLAG) || self.hasPermission(BEFORE_SWAP_OVERRIDE_PRICE_FLAG)
                )
        ) {
            bytes memory result;
            (success, result) = self.staticcallHooklet(
                IHooklet.beforeSwapView.selector, abi.encodeCall(IHooklet.beforeSwapView, (sender, key, params))
            );
            if (!success) return (false, false, 0, false, 0);
            (bool canOverrideFee, bool canOverridePrice) =
                (self.hasPermission(BEFORE_SWAP_OVERRIDE_FEE_FLAG), self.hasPermission(BEFORE_SWAP_OVERRIDE_PRICE_FLAG));

            // parse override data
            // equivalent to the following Solidity code:
            // (,feeOverridden, fee, priceOverridden, sqrtPriceX96) = abi.decode(result, (bytes4, bool, uint24, bool, uint160));
            /// @solidity memory-safe-assembly
            assembly {
                feeOverridden := mload(add(result, 0x40))
                fee := mload(add(result, 0x60))
                priceOverridden := mload(add(result, 0x80))
                sqrtPriceX96 := mload(add(result, 0xA0))
            }

            // ensure that the hooklet is allowed to override the fee and/or price
            // if the hooklet doesn't have a permission but the override is set, the override is ignored
            feeOverridden = canOverrideFee && feeOverridden;
            priceOverridden = canOverridePrice && priceOverridden;

            // clamp the override values to the valid range
            fee = feeOverridden ? uint24(fee.clamp(0, SWAP_FEE_BASE)) : 0;
            sqrtPriceX96 =
                priceOverridden ? uint160(sqrtPriceX96.clamp(TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE)) : 0;
        } else {
            return (true, false, 0, false, 0);
        }
    }

    /// @dev The hasPermission check is done outside of this function in order to avoid unnecessarily constructing returnData
    /// when calling it.
    function hookletAfterSwap(
        IHooklet self,
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        IHooklet.SwapReturnData memory returnData
    ) internal noSelfCall(self, sender) {
        self.callHooklet(
            IHooklet.afterSwap.selector, abi.encodeCall(IHooklet.afterSwap, (sender, key, params, returnData))
        );
    }

    function hookletAfterSwapView(
        IHooklet self,
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        IHooklet.SwapReturnData memory returnData
    ) internal view noSelfCall(self, sender) returns (bool success) {
        if (self.hasPermission(AFTER_SWAP_FLAG)) {
            (success,) = self.staticcallHooklet(
                IHooklet.afterSwapView.selector,
                abi.encodeCall(IHooklet.afterSwapView, (sender, key, params, returnData))
            );
        } else {
            success = true;
        }
    }

    /// @dev Calls IHooklet.afterSwap() after a rebalance order.
    /// @param self The hooklet to call
    /// @param sender The FloodPlain contract address
    /// @param key The Bunni pool's key
    /// @param zeroForOne True if the currency0 is the output token of the Flood order (thus the Bunni pool received currency0), false otherwise.
    /// @param orderInputAmount The amount of the input token of the Flood order
    /// @param orderOutputAmount The amount of the output token of the Flood order
    function hookletAfterRebalance(
        IHooklet self,
        address sender,
        PoolKey calldata key,
        bool zeroForOne,
        uint256 orderInputAmount,
        uint256 orderOutputAmount
    ) internal noSelfCall(self, sender) {
        self.callHooklet(
            IHooklet.afterSwap.selector,
            abi.encodeCall(
                IHooklet.afterSwap,
                (
                    sender,
                    key,
                    IPoolManager.SwapParams({
                        zeroForOne: zeroForOne,
                        amountSpecified: -int256(orderOutputAmount),
                        sqrtPriceLimitX96: 0
                    }),
                    IHooklet.SwapReturnData({
                        updatedSqrtPriceX96: 0,
                        updatedTick: 0,
                        inputAmount: orderOutputAmount,
                        outputAmount: orderInputAmount,
                        swapFee: 0,
                        totalLiquidity: 0
                    })
                )
            )
        );
    }

    function hasPermission(IHooklet self, uint160 flag) internal pure returns (bool) {
        return uint160(address(self)) & flag != 0;
    }
}
