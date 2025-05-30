// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import "../interfaces/IBaseHook.sol";

abstract contract BaseHook is IBaseHook {
    /// @notice The address of the pool manager
    IPoolManager internal immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /// @dev Only the pool manager may call this function
    modifier poolManagerOnly() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external virtual override returns (bytes4);

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24);
}
