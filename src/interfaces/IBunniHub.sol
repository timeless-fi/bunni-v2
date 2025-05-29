// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0;
pragma abicoder v2;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager, PoolKey} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {WETH} from "solady/tokens/WETH.sol";
import {ERC4626} from "solady/tokens/ERC4626.sol";

import "../types/LDFType.sol";
import "../types/IdleBalance.sol";
import "../base/SharedStructs.sol";
import {IERC20} from "./IERC20.sol";
import {IHooklet} from "./IHooklet.sol";
import {IOwnable} from "./IOwnable.sol";
import {IBunniHook} from "./IBunniHook.sol";
import {IBunniToken} from "./IBunniToken.sol";
import {PoolState} from "../types/PoolState.sol";
import {ILiquidityDensityFunction} from "./ILiquidityDensityFunction.sol";

/// @title BunniHub
/// @author zefram.eth
/// @notice The main contract LPs interact with. Each BunniKey corresponds to a BunniToken,
/// which is the ERC20 LP token for the Uniswap V3 position specified by the BunniKey.
/// Use deposit()/withdraw() to mint/burn LP tokens, and use compound() to compound the swap fees
/// back into the LP position.
interface IBunniHub is IUnlockCallback, IOwnable {
    /// @notice Emitted when liquidity is increased via deposit
    /// @param sender The msg.sender address
    /// @param recipient The address of the account that received the share tokens
    /// @param poolId The Uniswap V4 pool's ID
    /// @param amount0 The amount of token0 that was paid for the increase in liquidity
    /// @param amount1 The amount of token1 that was paid for the increase in liquidity
    /// @param shares The amount of share tokens minted to the recipient
    event Deposit(
        address indexed sender,
        address indexed recipient,
        PoolId indexed poolId,
        uint256 amount0,
        uint256 amount1,
        uint256 shares
    );
    /// @notice Emitted when a withdrawal is queued
    /// @param sender The msg.sender address
    /// @param poolId The Uniswap V4 pool's ID
    /// @param shares The amount of share tokens queued for withdrawal
    event QueueWithdraw(address indexed sender, PoolId indexed poolId, uint256 shares);
    /// @notice Emitted when liquidity is decreased via withdrawal
    /// @param sender The msg.sender address
    /// @param recipient The address of the account that received the collected tokens
    /// @param poolId The Uniswap V4 pool's ID
    /// @param amount0 The amount of token0 that was accounted for the decrease in liquidity
    /// @param amount1 The amount of token1 that was accounted for the decrease in liquidity
    /// @param shares The amount of share tokens burnt from the sender
    event Withdraw(
        address indexed sender,
        address indexed recipient,
        PoolId indexed poolId,
        uint256 amount0,
        uint256 amount1,
        uint256 shares
    );
    /// @notice Emitted when a new IBunniToken is created
    /// @param bunniToken The BunniToken associated with the call
    /// @param poolId The Uniswap V4 pool's ID
    event NewBunni(IBunniToken indexed bunniToken, PoolId indexed poolId);
    /// @notice Emitted when a new address is added to or removed from the pauser set
    /// @param guy The address that was added or removed from the pauser set
    /// @param isPauser True if the address was added to the pauser set, false if it was removed
    event SetPauser(address indexed guy, bool indexed isPauser);
    /// @notice Emitted when the pause flags are set
    /// @param pauseFlags The new pause flags, each bit corresponds to a function in BunniHub and is set to 1 if the function is paused
    event SetPauseFlags(uint8 indexed pauseFlags);
    /// @notice Emitted when the pause fuse is burned
    event BurnPauseFuse();
    /// @notice Emitted when a hook is whitelisted or blacklisted
    /// @param hook The hook that was whitelisted or blacklisted
    /// @param whitelisted True if the hook was whitelisted, false if it was blacklisted
    event SetHookWhitelist(IBunniHook indexed hook, bool indexed whitelisted);

    /// @param poolKey The PoolKey of the Uniswap V4 pool
    /// @param recipient The recipient of the minted share tokens
    /// @param refundRecipient The recipient of the refunded ETH
    /// @param amount0Desired The desired amount of token0 to be spent,
    /// @param amount1Desired The desired amount of token1 to be spent,
    /// @param amount0Min The minimum amount of token0 to spend, which serves as a slippage check,
    /// @param amount1Min The minimum amount of token1 to spend, which serves as a slippage check,
    /// @param vaultFee0 When we deposit token0 into vault0, the deposit amount is multiplied by WAD / (WAD - vaultFee0),
    /// @param vaultFee1 When we deposit token1 into vault1, the deposit amount is multiplied by WAD / (WAD - vaultFee1),
    /// @param deadline The time by which the transaction must be included to effect the change
    struct DepositParams {
        PoolKey poolKey;
        address recipient;
        address refundRecipient;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 vaultFee0;
        uint256 vaultFee1;
        uint256 deadline;
    }

    /// @notice Increases the amount of liquidity in a position, with tokens paid by the `msg.sender`
    /// @dev Must be called after the corresponding BunniToken has been deployed via deployBunniToken()
    /// @param params The input parameters
    /// poolKey The PoolKey of the Uniswap V4 pool
    /// recipient The recipient of the minted share tokens
    /// refundRecipient The recipient of the refunded ETH
    /// amount0Desired The desired amount of token0 to be spent,
    /// amount1Desired The desired amount of token1 to be spent,
    /// amount0Min The minimum amount of token0 to spend, which serves as a slippage check,
    /// amount1Min The minimum amount of token1 to spend, which serves as a slippage check,
    /// vaultFee0 When we deposit token0 into vault0, the deposit amount is multiplied by WAD / (WAD - vaultFee0),
    /// vaultFee1 When we deposit token1 into vault1, the deposit amount is multiplied by WAD / (WAD - vaultFee1),
    /// deadline The time by which the transaction must be included to effect the change
    /// @return shares The new share tokens minted to the sender
    /// @return amount0 The amount of token0 to acheive resulting liquidity
    /// @return amount1 The amount of token1 to acheive resulting liquidity
    function deposit(DepositParams calldata params)
        external
        payable
        returns (uint256 shares, uint256 amount0, uint256 amount1);

    /// @param poolKey The PoolKey of the Uniswap V4 pool
    /// @param shares The amount of share tokens to burn. Ignored if an expired queued withdrawal exists.
    struct QueueWithdrawParams {
        PoolKey poolKey;
        uint200 shares;
    }

    /// @notice Queues a withdrawal of liquidity. Need to use this before calling withdraw() if am-AMM is enabled
    /// and a manager exists for the pool. A queued withdrawal is unlocked after WITHDRAW_DELAY (1 minutes) has passed,
    /// and before WITHDRAW_GRACE_PERIOD (15 minutes) has passed after it's been unlocked. This ensures the am-AMM manager
    /// has an opportunity to execute any arbitrage trades before a withdrawal is processed.
    /// @param params The input parameters
    /// poolKey The PoolKey of the Uniswap V4 pool
    /// shares The amount of share tokens to burn
    function queueWithdraw(QueueWithdrawParams calldata params) external;

    /// @param poolKey The PoolKey of the Uniswap V4 pool
    /// @param recipient The recipient of the withdrawn tokens
    /// @param shares The amount of share tokens to burn
    /// @param amount0Min The minimum amount of token0 that should be accounted for the burned liquidity
    /// @param amount1Min The minimum amount of token1 that should be accounted for the burned liquidity
    /// @param deadline The time by which the transaction must be included to effect the change
    /// @param useQueuedWithdrawal If true, queued withdrawal share tokens will be used
    struct WithdrawParams {
        PoolKey poolKey;
        address recipient;
        uint256 shares;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
        bool useQueuedWithdrawal;
    }

    /// @notice Decreases the amount of liquidity in the position and sends the tokens to the sender.
    /// If withdrawing ETH, need to follow up with unwrapWETH9() and sweepToken()
    /// @dev Must be called after the corresponding BunniToken has been deployed via deployBunniToken()
    /// @param params The input parameters
    /// poolKey The Uniswap v4 pool's key
    /// recipient The recipient of the withdrawn tokens
    /// shares The amount of share tokens to burn,
    /// amount0Min The minimum amount of token0 that should be accounted for the burned liquidity,
    /// amount1Min The minimum amount of token1 that should be accounted for the burned liquidity,
    /// deadline The time by which the transaction must be included to effect the change
    /// @return amount0 The amount of token0 withdrawn to the recipient
    /// @return amount1 The amount of token1 withdrawn to the recipient
    function withdraw(WithdrawParams calldata params) external returns (uint256 amount0, uint256 amount1);

    /// @param currency0 The token0 of the Uniswap V4 pool
    /// @param currency1 The token1 of the Uniswap V4 pool
    /// @param tickSpacing The tick spacing of the Uniswap V4 pool
    /// @param twapSecondsAgo The TWAP time period to use for the liquidity density function
    /// @param liquidityDensityFunction The liquidity density function to use
    /// @param ldfType The type of LDF. See LDFType.sol for details.
    /// @param hooklet The hooklet to use for the Bunni pool. If it's address(0), then a hooklet is not used.
    /// @param ldfParams The parameters for the liquidity density function
    /// @param hooks The hooks to use for the Uniswap V4 pool
    /// @param hookParams The parameters for the hooks
    /// @param vault0 The vault for token0. If address(0), then a vault is not used.
    /// @param vault1 The vault for token1. If address(0), then a vault is not used.
    /// @param minRawTokenRatio0 The minimum (rawBalance / balance) ratio for token0
    /// @param targetRawTokenRatio0 The target (rawBalance / balance) ratio for token0
    /// @param maxRawTokenRatio0 The maximum (rawBalance / balance) ratio for token0
    /// @param minRawTokenRatio1 The minimum (rawBalance / balance) ratio for token1
    /// @param targetRawTokenRatio1 The target (rawBalance / balance) ratio for token1
    /// @param maxRawTokenRatio1 The maximum (rawBalance / balance) ratio for token1
    /// @param sqrtPriceX96 The initial sqrt price of the Uniswap V4 pool
    /// @param name The name of the BunniToken
    /// @param symbol The symbol of the BunniToken
    /// @param owner The owner of the BunniToken. Only has the power to set the metadata URI.
    /// @param metadataURI The initial metadata URI of the BunniToken, containing info like description, image, etc.
    /// @param salt The salt for deploying the BunniToken via CREATE3.
    struct DeployBunniTokenParams {
        Currency currency0;
        Currency currency1;
        int24 tickSpacing;
        uint24 twapSecondsAgo;
        ILiquidityDensityFunction liquidityDensityFunction;
        IHooklet hooklet;
        LDFType ldfType;
        bytes32 ldfParams;
        IBunniHook hooks;
        bytes hookParams;
        ERC4626 vault0;
        ERC4626 vault1;
        uint24 minRawTokenRatio0;
        uint24 targetRawTokenRatio0;
        uint24 maxRawTokenRatio0;
        uint24 minRawTokenRatio1;
        uint24 targetRawTokenRatio1;
        uint24 maxRawTokenRatio1;
        uint160 sqrtPriceX96;
        bytes32 name;
        bytes32 symbol;
        address owner;
        string metadataURI;
        bytes32 salt;
    }

    /// @notice Deploys the BunniToken contract for a Bunni position. This token
    /// represents a user's share in the Uniswap V4 LP position.
    /// Only whitelisted hooks may be used.
    /// @dev The BunniToken is deployed via CREATE3, which allows for a deterministic address.
    /// @param params The input parameters
    /// currency0 The token0 of the Uniswap V4 pool
    /// currency1 The token1 of the Uniswap V4 pool
    /// tickSpacing The tick spacing of the Uniswap V4 pool
    /// twapSecondsAgo The TWAP time period to use for the liquidity density function
    /// liquidityDensityFunction The liquidity density function to use
    /// hooklet The hooklet to use for the Bunni pool. If it's address(0), then a hooklet is not used.
    /// ldfParams The parameters for the liquidity density function
    /// hooks The hooks to use for the Uniswap V4 pool
    /// hookParams The parameters for the hooks
    /// vault0 The vault for token0. If address(0), then a vault is not used.
    /// vault1 The vault for token1. If address(0), then a vault is not used.
    /// minRawTokenRatio0 The minimum (rawBalance / balance) ratio for token0
    /// targetRawTokenRatio0 The target (rawBalance / balance) ratio for token0
    /// maxRawTokenRatio0 The maximum (rawBalance / balance) ratio for token0
    /// minRawTokenRatio1 The minimum (rawBalance / balance) ratio for token1
    /// targetRawTokenRatio1 The target (rawBalance / balance) ratio for token1
    /// maxRawTokenRatio1 The maximum (rawBalance / balance) ratio for token1
    /// sqrtPriceX96 The initial sqrt price of the Uniswap V4 pool
    /// name The name of the BunniToken
    /// symbol The symbol of the BunniToken
    /// owner The owner of the BunniToken. Only has the power to set the metadata URI.
    /// metadataURI The initial metadata URI of the BunniToken, containing info like description, image, etc.
    /// salt The salt for deploying the BunniToken via CREATE3.
    /// @return token The deployed BunniToken
    /// @return key The PoolKey of the Uniswap V4 pool
    function deployBunniToken(DeployBunniTokenParams calldata params)
        external
        returns (IBunniToken token, PoolKey memory key);

    /// @notice Called by the hook to execute a generalized swap from one token to the other. Also used during rebalancing.
    /// @dev If the raw balance is insufficient, vault reserves will be automatically used.
    /// Will update vault reserves if the raw/reserve ratio is outside of the bounds.
    /// @param key The PoolKey of the Uniswap V4 pool
    /// @param zeroForOne True if the swap is for token0->token1, false if token1->token0
    /// @param inputAmount The amount of the input token to pull from the hook
    /// @param outputAmount The amount of the output token to push to the hook
    /// @param shouldSurge True if the pool should surge before the swap
    function hookHandleSwap(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 inputAmount,
        uint256 outputAmount,
        bool shouldSurge
    ) external;

    /// @notice Called by the hook to set the idle balance of a Bunni pool.
    /// @param key The PoolKey of the Uniswap V4 pool
    /// @param newIdleBalance The new idle balance of the pool
    function hookSetIdleBalance(PoolKey calldata key, IdleBalance newIdleBalance) external;

    /// @notice Called by the hook to give assets to a Bunni pool it manages.
    /// The assets are given in the form of PoolManager ERC-6909 claim tokens.
    /// @dev This function does NOT use nonReentrant in order to support rebalancing.
    /// Thus it is kept as simple as possible, the only external call it makes is to PoolManager,
    /// and it follows the checks-effects-interactions pattern.
    /// It only updates the raw balance and thus could push the raw balance ratio beyond the max,
    /// but we're OK with it since the next user swap will fix it. This decision is also to maximize simplicity.
    /// @param key The PoolKey of the Uniswap V4 pool
    /// @param isCurrency0 True if the amount is for currency0, false if it's for currency1
    /// @param amount The amount of currency to give to the pool
    function hookGive(PoolKey calldata key, bool isCurrency0, uint256 amount) external;

    /// @notice Adds or removes an address from the pauser set. Only callable by the owner.
    /// @param guy The address to add or remove from the pauser set
    /// @param isPauser True if the address should be added to the pauser set, false if it should be removed
    function setPauser(address guy, bool isPauser) external;

    /// @notice Sets the pause flags. Only callable by the owner.
    /// @param pauseFlags The new pause flags, each bit corresponds to a function in BunniHub and is set to 1 if the function is paused
    function setPauseFlags(uint8 pauseFlags) external;

    /// @notice Burns the pause fuse. Only callable by the owner.
    /// All functions are permanently unpaused after this function is called.
    function burnPauseFuse() external;

    /// @notice Whitelists or blacklists a hook. Only callable by the owner.
    /// Only whitelisted hooks may be used when creating a new Bunni pool.
    /// @param hook The hook to whitelist or blacklist
    /// @param whitelisted True if the hook should be whitelisted, false if it should be blacklisted
    function setHookWhitelist(IBunniHook hook, bool whitelisted) external;

    /// @notice Called by key.hooks to lock BunniHub before a rebalance order's execution.
    /// @param key The PoolKey of the Uniswap v4 pool
    function lockForRebalance(PoolKey calldata key) external;

    /// @notice The state of a Bunni pool.
    function poolState(PoolId poolId) external view returns (PoolState memory);

    /// @notice The PoolState struct of a given pool with only the immutable params filled out.
    function poolParams(PoolId poolId) external view returns (PoolState memory);

    /// @notice The BunniToken of a given pool. address(0) if the pool is not a Bunni pool.
    function bunniTokenOfPool(PoolId poolId) external view returns (IBunniToken);

    /// @notice The hooklet of a given pool. address(0) if the pool is not a Bunni pool.
    function hookletOfPool(PoolId poolId) external view returns (IHooklet);

    /// @notice The params of the given Bunni pool's hook. bytes("") if the pool is not a Bunni pool.
    function hookParams(PoolId poolId) external view returns (bytes memory);

    /// @notice The next available nonce of the given Bunni subspace.
    function nonce(bytes32 bunniSubspace) external view returns (uint24);

    /// @notice The PoolId of a given BunniToken.
    function poolIdOfBunniToken(IBunniToken bunniToken) external view returns (PoolId);

    /// @notice The token balances of a Bunni pool. Reserves in vaults are converted to raw token balances via ERC4626.previewRedeem().
    function poolBalances(PoolId poolId) external view returns (uint256 balance0, uint256 balance1);

    /// @notice The idle balance of a Bunni pool.
    function idleBalance(PoolId poolId) external view returns (IdleBalance);

    /// @notice Returns true if the given address is a pauser who can pause/unpause external functions.
    function isPauser(address guy) external view returns (bool);

    /// @notice The pause flags and pause fuse status.
    /// @return pauseFlags The pause flags, each bit corresponds to a function in BunniHub and is set to 1 if the function is paused
    /// @return unpauseFuse The pause fuse status. If true, all functions are permanently unpaused
    function getPauseStatus() external view returns (uint8 pauseFlags, bool unpauseFuse);

    /// @notice The init data of a Bunni pool. Stored in transient storage and used
    /// during the IHooks.afterInitialize() call.
    function poolInitData() external view returns (bytes memory);

    /// @notice Whether the given hook is whitelisted.
    /// @param hook The hook to check
    function hookIsWhitelisted(IBunniHook hook) external view returns (bool);
}
