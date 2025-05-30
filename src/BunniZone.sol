// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "flood-contracts/src/interfaces/IZone.sol";
import "flood-contracts/src/interfaces/IFloodPlain.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IAmAmm} from "biddog/interfaces/IAmAmm.sol";

import {Ownable} from "./base/Ownable.sol";
import {IBunniHook} from "./interfaces/IBunniHook.sol";
import {IBunniZone} from "./interfaces/IBunniZone.sol";

contract BunniZone is IBunniZone, Ownable {
    using PoolIdLibrary for PoolKey;

    mapping(address => bool) public isWhitelisted;

    constructor(address initialOwner) {
        _initializeOwner(initialOwner);
    }

    /// -----------------------------------------------------------------------
    /// Owner functions
    /// -----------------------------------------------------------------------

    function setIsWhitelisted(address account, bool isWhitelisted_) external onlyOwner {
        isWhitelisted[account] = isWhitelisted_;
        emit SetIsWhitelisted(account, isWhitelisted_);
    }

    /// -----------------------------------------------------------------------
    /// Flood IZone compliance
    /// -----------------------------------------------------------------------

    /// @inheritdoc IZone
    /// @dev Only allows whitelisted fulfillers and am-AMM manager of the pool to fulfill orders.
    function validate(IFloodPlain.Order calldata order, address fulfiller) external view returns (bool) {
        // extract PoolKey from order's preHooks
        // offset is 36 which is 4 bytes for function selector and 32 bytes for `bool isPreHook`
        IBunniHook.RebalanceOrderHookArgs memory hookArgs =
            abi.decode(order.preHooks[0].data[36:], (IBunniHook.RebalanceOrderHookArgs));
        PoolKey memory key = hookArgs.key;
        PoolId id = key.toId();

        // query the hook for the am-AMM manager
        IAmAmm amAmm = IAmAmm(address(key.hooks));
        IAmAmm.Bid memory topBid = amAmm.getTopBid(id);

        // allow fulfiller if they are whitelisted or if they are the am-AMM manager
        return isWhitelisted[fulfiller] || topBid.manager == fulfiller;
    }

    /// @inheritdoc IZone
    function fee(IFloodPlain.Order calldata, address) external pure returns (IZone.FeeInfo memory) {
        return IZone.FeeInfo(address(0), 0);
    }
}
