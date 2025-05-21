// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {IPoolManager, PoolKey} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {IBunniHub} from "./IBunniHub.sol";
import {IBunniToken} from "./IBunniToken.sol";

/// @title Hooklet
/// @notice Hooklets let developers execute custom logic before/after Bunni operations.
/// Each Bunni pool can have one hooklet attached to it. The least significant bits of the hooklet's
/// address is used to flag which hooklet functions should be callled.
interface IHooklet {
    /// @notice Return data of an initialize operation.
    /// @member bunniToken The BunniToken deployed.
    /// @member key The Uniswap v4 pool's key.
    struct InitializeReturnData {
        IBunniToken bunniToken;
        PoolKey key;
    }

    /// @notice Return data of a deposit operation.
    /// @member shares The amount of shares minted.
    /// @member amount0 The amount of token0 deposited.
    /// @member amount1 The amount of token1 deposited.
    struct DepositReturnData {
        uint256 shares;
        uint256 amount0;
        uint256 amount1;
    }

    /// @notice Return data of a withdraw operation.
    /// @member amount0 The amount of token0 withdrawn.
    /// @member amount1 The amount of token1 withdrawn.
    struct WithdrawReturnData {
        uint256 amount0;
        uint256 amount1;
    }

    /// @notice Return data of a swap operation.
    /// @member updatedSqrtPriceX96 The pool's updated sqrt price after the swap.
    /// @member updatedTick The pool's updated tick after the swap.
    /// @member inputAmount The amount of input tokens swapped.
    /// @member outputAmount The amount of output tokens received.
    /// @member swapFee The swap fee used for the swap. 6 decimals.
    /// @member totalLiquidity The pool's total liquidity after the swap.
    struct SwapReturnData {
        uint160 updatedSqrtPriceX96;
        int24 updatedTick;
        uint256 inputAmount;
        uint256 outputAmount;
        uint24 swapFee;
        uint256 totalLiquidity;
    }

    /// @notice Overrides the swap fee of a pool before the swap is executed.
    /// Ignored if the pool has an am-AMM manager.
    /// @member overridden If true, the swap fee is overridden.
    /// @member fee The swap fee to use for the swap. 6 decimals.
    struct BeforeSwapFeeOverride {
        bool overridden;
        uint24 fee;
    }

    /// @notice Overrides the pool's spot price before the swap is executed.
    /// @member overridden If true, the pool's spot price is overridden.
    /// @member sqrtPriceX96 The spot price to use for the swap. Q96 value.
    struct BeforeSwapPriceOverride {
        bool overridden;
        uint160 sqrtPriceX96;
    }

    /// @notice Called before a BunniToken transfer operation.
    /// @param sender The address that initiated the transfer.
    /// @param key The Uniswap v4 pool's key.
    /// @param bunniToken The BunniToken being transferred.
    /// @param from The address that is sending the tokens.
    /// @param to The address that is receiving the tokens.
    /// @param amount The amount of tokens being transferred.
    /// @return selector IHooklet.beforeTransfer.selector if the call was successful.
    function beforeTransfer(
        address sender,
        PoolKey calldata key,
        IBunniToken bunniToken,
        address from,
        address to,
        uint256 amount
    ) external returns (bytes4 selector);

    /// @notice Called after a BunniToken transfer operation.
    /// @param sender The address that initiated the transfer.
    /// @param key The Uniswap v4 pool's key.
    /// @param bunniToken The BunniToken being transferred.
    /// @param from The address that is sending the tokens.
    /// @param to The address that is receiving the tokens.
    /// @param amount The amount of tokens being transferred.
    /// @return selector IHooklet.afterTransfer.selector if the call was successful.
    function afterTransfer(
        address sender,
        PoolKey calldata key,
        IBunniToken bunniToken,
        address from,
        address to,
        uint256 amount
    ) external returns (bytes4 selector);

    /// @notice Called before a pool is initialized.
    /// @param sender The address of the account that initiated the initialization.
    /// @param params The initialization's input parameters.
    /// @return selector IHooklet.beforeInitialize.selector if the call was successful.
    function beforeInitialize(address sender, IBunniHub.DeployBunniTokenParams calldata params)
        external
        returns (bytes4 selector);

    /// @notice Called after a pool is initialized.
    /// @param sender The address of the account that initiated the initialization.
    /// @param params The initialization's input parameters.
    /// @param returnData The initialization operation's return data.
    /// @return selector IHooklet.afterInitialize.selector if the call was successful.
    function afterInitialize(
        address sender,
        IBunniHub.DeployBunniTokenParams calldata params,
        InitializeReturnData calldata returnData
    ) external returns (bytes4 selector);

    /// @notice Called before a deposit operation.
    /// @param sender The address of the account that initiated the deposit.
    /// @param params The deposit's input parameters.
    /// @return selector IHooklet.beforeDeposit.selector if the call was successful.
    function beforeDeposit(address sender, IBunniHub.DepositParams calldata params)
        external
        returns (bytes4 selector);

    /// @notice View version of beforeDeposit(), used when computing deposit quotes like in BunniQuoter.
    /// Should always have the same behavior as beforeDeposit().
    /// @param sender The address of the account that initiated the deposit.
    /// @param params The deposit's input parameters.
    /// @return selector IHooklet.beforeDeposit.selector if the call was successful.
    function beforeDepositView(address sender, IBunniHub.DepositParams calldata params)
        external
        view
        returns (bytes4 selector);

    /// @notice Called after a deposit operation.
    /// @param sender The address of the account that initiated the deposit.
    /// @param params The deposit's input parameters.
    /// @param returnData The deposit operation's return data.
    /// @return selector IHooklet.afterDeposit.selector if the call was successful.
    function afterDeposit(
        address sender,
        IBunniHub.DepositParams calldata params,
        DepositReturnData calldata returnData
    ) external returns (bytes4 selector);

    /// @notice View version of afterDeposit(), used when computing deposit quotes like in BunniQuoter.
    /// Should always have the same behavior as afterDeposit().
    /// @param sender The address of the account that initiated the deposit.
    /// @param params The deposit's input parameters.
    /// @param returnData The deposit operation's return data.
    /// @return selector IHooklet.afterDeposit.selector if the call was successful.
    function afterDepositView(
        address sender,
        IBunniHub.DepositParams calldata params,
        DepositReturnData calldata returnData
    ) external view returns (bytes4 selector);

    /// @notice Called before a withdraw operation.
    /// @param sender The address of the account that initiated the withdraw.
    /// @param params The withdraw's input parameters.
    /// @return selector IHooklet.beforeWithdraw.selector if the call was successful.
    function beforeWithdraw(address sender, IBunniHub.WithdrawParams calldata params)
        external
        returns (bytes4 selector);

    /// @notice View version of beforeWithdraw(), used when computing withdraw quotes like in BunniQuoter.
    /// Should always have the same behavior as beforeWithdraw().
    /// @param sender The address of the account that initiated the withdraw.
    /// @param params The withdraw's input parameters.
    /// @return selector IHooklet.beforeWithdraw.selector if the call was successful.
    function beforeWithdrawView(address sender, IBunniHub.WithdrawParams calldata params)
        external
        view
        returns (bytes4 selector);

    /// @notice Called after a withdraw operation.
    /// @param sender The address of the account that initiated the withdraw.
    /// @param params The withdraw's input parameters.
    /// @param returnData The withdraw operation's return data.
    /// @return selector IHooklet.afterWithdraw.selector if the call was successful.
    function afterWithdraw(
        address sender,
        IBunniHub.WithdrawParams calldata params,
        WithdrawReturnData calldata returnData
    ) external returns (bytes4 selector);

    /// @notice View version of afterWithdraw(), used when computing withdraw quotes like in BunniQuoter.
    /// Should always have the same behavior as afterWithdraw().
    /// @param sender The address of the account that initiated the withdraw.
    /// @param params The withdraw's input parameters.
    /// @param returnData The withdraw operation's return data.
    /// @return selector IHooklet.afterWithdraw.selector if the call was successful.
    function afterWithdrawView(
        address sender,
        IBunniHub.WithdrawParams calldata params,
        WithdrawReturnData calldata returnData
    ) external view returns (bytes4 selector);

    /// @notice Called before a swap operation. Allows the hooklet to override the swap fee & price
    /// of the pool before the swap is executed.
    /// @param sender The address of the account that initiated the swap.
    /// @param key The Uniswap v4 pool's key.
    /// @param params The swap's input parameters.
    /// @return selector IHooklet.beforeSwap.selector if the call was successful.
    /// @return feeOverriden If true, the swap fee is overridden. If the pool has an am-AMM manager
    /// then the fee override is ignored.
    /// @return fee The swap fee to use for the swap. 6 decimals.
    /// @return priceOverridden If true, the pool's spot price is overridden.
    /// @return sqrtPriceX96 The spot price to use for the swap. Q96 value.
    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params)
        external
        returns (bytes4 selector, bool feeOverriden, uint24 fee, bool priceOverridden, uint160 sqrtPriceX96);

    /// @notice View version of beforeSwap(), used when computing swap quotes like in BunniQuoter.
    /// Should always return the same values as beforeSwap().
    /// @param sender The address of the account that initiated the swap.
    /// @param key The Uniswap v4 pool's key.
    /// @param params The swap's input parameters.
    /// @return selector IHooklet.beforeSwap.selector if the call was successful.
    /// @return feeOverriden If true, the swap fee is overridden. If the pool has an am-AMM manager
    /// then the fee override is ignored.
    /// @return fee The swap fee to use for the swap. 6 decimals.
    /// @return priceOverridden If true, the pool's spot price is overridden.
    /// @return sqrtPriceX96 The spot price to use for the swap. Q96 value.
    function beforeSwapView(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params)
        external
        view
        returns (bytes4 selector, bool feeOverriden, uint24 fee, bool priceOverridden, uint160 sqrtPriceX96);

    /// @notice Called after a swap operation.
    /// @dev Also called after a rebalance order execution, in which case returnData will only have
    /// inputAmount and outputAmount filled out.
    /// @param sender The address of the account that initiated the swap.
    /// @param key The Uniswap v4 pool's key.
    /// @param params The swap's input parameters.
    /// @param returnData The swap operation's return data.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        SwapReturnData calldata returnData
    ) external returns (bytes4 selector);

    /// @notice View version of afterSwap(), used when computing swap quotes like in BunniQuoter.
    /// Should always have the same behavior as afterSwap().
    /// @param sender The address of the account that initiated the swap.
    /// @param key The Uniswap v4 pool's key.
    /// @param params The swap's input parameters.
    /// @param returnData The swap operation's return data.
    /// @return selector IHooklet.afterSwap.selector if the call was successful.
    function afterSwapView(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        SwapReturnData calldata returnData
    ) external view returns (bytes4 selector);
}
