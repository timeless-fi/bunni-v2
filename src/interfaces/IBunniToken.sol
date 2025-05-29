// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0;

import "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {IERC20} from "./IERC20.sol";
import {IOwnable} from "./IOwnable.sol";
import {IHooklet} from "./IHooklet.sol";
import {IBunniHub} from "./IBunniHub.sol";
import {IERC20Lockable} from "./IERC20Lockable.sol";

/// @title BunniToken
/// @author zefram.eth
/// @notice ERC20 token that represents a user's LP position
interface IBunniToken is IERC20, IERC20Lockable, IOwnable {
    event SetMetadataURI(string newURI);

    function hub() external view returns (IBunniHub);

    function token0() external view returns (Currency);

    function token1() external view returns (Currency);

    function poolManager() external view returns (IPoolManager);

    function poolKey() external view returns (PoolKey memory);

    function hooklet() external view returns (IHooklet);

    function mint(address to, uint256 amount) external;

    function burn(address from, uint256 amount) external;

    function burn(uint256 amount) external;

    function initialize(address owner_, string calldata metadataURI_) external;

    function metadataURI() external view returns (string memory);

    function setMetadataURI(string calldata metadataURI_) external;

    /// @notice Increments the EIP-2612 permit nonce of the caller to invalidate permit signatures.
    function incrementNonce() external;
}
