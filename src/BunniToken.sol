// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.15;

import {Clone} from "clones-with-immutable-args/Clone.sol";

import {LibMulticaller} from "multicaller/LibMulticaller.sol";

import "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import "./base/Errors.sol";
import "./base/Constants.sol";
import {ERC20} from "./base/ERC20.sol";
import {Ownable} from "./base/Ownable.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {HookletLib} from "./lib/HookletLib.sol";
import {IHooklet} from "./interfaces/IHooklet.sol";
import {IBunniHub} from "./interfaces/IBunniHub.sol";
import {IBunniToken} from "./interfaces/IBunniToken.sol";
import {ERC20Lockable} from "./base/ERC20Lockable.sol";

/// @title BunniToken
/// @author zefram.eth
/// @notice ERC20 token that represents a user's LP position
contract BunniToken is IBunniToken, ERC20Lockable, Clone, Ownable {
    /// -----------------------------------------------------------------------
    /// Library usage
    /// -----------------------------------------------------------------------

    using FixedPointMathLib for *;
    using HookletLib for IHooklet;
    using SafeTransferLib for address;
    using CurrencyLibrary for Currency;

    /// -----------------------------------------------------------------------
    /// Storage
    /// -----------------------------------------------------------------------

    string public metadataURI;

    /// -----------------------------------------------------------------------
    /// Immutable params
    /// -----------------------------------------------------------------------
    /// Packed data layout:
    /// [0:20] address hub
    /// [20:40] address token0
    /// [40:60] address token1
    /// [60:92] bytes32 name
    /// [92:124] bytes32 symbol
    /// [124:144] address poolManager
    /// [144:147] uint24 fee
    /// [147:150] int24 tickSpacing
    /// [150:170] address hooks
    /// [170:190] address hooklet
    /// -----------------------------------------------------------------------

    function hub() public pure override returns (IBunniHub) {
        return IBunniHub(_getArgAddress(0));
    }

    function token0() public pure override returns (Currency) {
        return Currency.wrap(_getArgAddress(20));
    }

    function token1() public pure override returns (Currency) {
        return Currency.wrap(_getArgAddress(40));
    }

    function name() public pure override(ERC20, IERC20) returns (string memory) {
        return string(abi.encodePacked(_getArgUint256(60)));
    }

    function symbol() public pure override(ERC20, IERC20) returns (string memory) {
        return string(abi.encodePacked(_getArgUint256(92)));
    }

    function poolManager() public pure override returns (IPoolManager) {
        return IPoolManager(_getArgAddress(124));
    }

    function poolKey() public pure override returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(_getArgAddress(20)),
            currency1: Currency.wrap(_getArgAddress(40)),
            fee: _getArgUint24(144),
            tickSpacing: int24(_getArgUint24(147)),
            hooks: IHooks(_getArgAddress(150))
        });
    }

    function hooklet() public pure override returns (IHooklet) {
        return IHooklet(_getArgAddress(170));
    }

    /// -----------------------------------------------------------------------
    /// Initialization
    /// -----------------------------------------------------------------------

    function initialize(address owner_, string calldata metadataURI_) external override {
        if (msg.sender != address(hub())) revert BunniToken__NotBunniHub();
        _initializeOwner(owner_);
        metadataURI = metadataURI_;
        emit SetMetadataURI(metadataURI_);
    }

    /// -----------------------------------------------------------------------
    /// Minting & burning
    /// -----------------------------------------------------------------------

    function mint(address to, uint256 amount) external override {
        if (msg.sender != address(hub())) revert BunniToken__NotBunniHub();

        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external override {
        if (msg.sender != address(hub())) revert BunniToken__NotBunniHub();

        _burn(from, amount);
    }

    function burn(uint256 amount) external override {
        _burn(msg.sender, amount);
    }

    /// -----------------------------------------------------------------------
    /// Metadata
    /// -----------------------------------------------------------------------

    function setMetadataURI(string calldata metadataURI_) external override onlyOwner {
        metadataURI = metadataURI_;
        emit SetMetadataURI(metadataURI_);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        // call hooklet
        IHooklet hooklet_ = hooklet();
        if (hooklet_.hasPermission(HookletLib.BEFORE_TRANSFER_FLAG)) {
            address msgSender = LibMulticaller.senderOrSigner();
            hooklet_.hookletBeforeTransfer(msgSender, poolKey(), this, from, to, amount);
        }
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        // call hooklet
        IHooklet hooklet_ = hooklet();
        if (hooklet_.hasPermission(HookletLib.AFTER_TRANSFER_FLAG)) {
            address msgSender = LibMulticaller.senderOrSigner();
            hooklet_.hookletAfterTransfer(msgSender, poolKey(), this, from, to, amount);
        }
    }

    /// -----------------------------------------------------------------------
    /// EIP-2612
    /// -----------------------------------------------------------------------

    function incrementNonce() external override {
        address msgSender = LibMulticaller.senderOrSigner();
        _incrementNonce(msgSender);
    }

    /// -----------------------------------------------------------------------
    /// Internal utilities
    /// -----------------------------------------------------------------------

    /// @notice Reads an immutable arg with type uint24
    /// @param argOffset The offset of the arg in the packed data
    /// @return arg The arg value
    function _getArgUint24(uint256 argOffset) internal pure returns (uint24 arg) {
        uint256 offset = _getImmutableArgsOffset();
        // solhint-disable-next-line no-inline-assembly
        assembly {
            arg := shr(0xe8, calldataload(add(offset, argOffset)))
        }
    }
}
