// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.19;

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager, PoolKey} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

import {LibMulticaller} from "multicaller/LibMulticaller.sol";

import {WETH} from "solady/tokens/WETH.sol";
import {SSTORE2} from "solady/utils/SSTORE2.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {LibTransient} from "solady/utils/LibTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import "./lib/Math.sol";
import "./base/Errors.sol";
import "./lib/VaultMath.sol";
import "./base/Constants.sol";
import "./base/SharedStructs.sol";
import "./interfaces/IBunniHub.sol";
import {Ownable} from "./base/Ownable.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {BunniHubLogic} from "./lib/BunniHubLogic.sol";
import {IBunniHook} from "./interfaces/IBunniHook.sol";
import {IBunniToken} from "./interfaces/IBunniToken.sol";
import {ReentrancyGuard} from "./base/ReentrancyGuard.sol";
import {PoolState, getPoolState, getPoolParams} from "./types/PoolState.sol";
import {ExcessivelySafeTransfer2Lib} from "./lib/ExcessivelySafeTransfer2Lib.sol";

/// @title BunniHub
/// @author zefram.eth
/// @notice The main contract LPs interact with. Each BunniKey corresponds to a BunniToken,
/// which is the ERC20 LP token for the Uniswap V4 position specified by the BunniKey.
/// Use deposit()/withdraw() to mint/burn LP tokens.
contract BunniHub is IBunniHub, Ownable, ReentrancyGuard {
    using SafeCastLib for *;
    using LibTransient for *;
    using SSTORE2 for address;
    using FixedPointMathLib for *;
    using PoolIdLibrary for PoolKey;
    using SafeTransferLib for address;
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;
    using ExcessivelySafeTransfer2Lib for address;

    /// -----------------------------------------------------------------------
    /// Constants
    /// -----------------------------------------------------------------------

    uint256 private constant INIT_DATA_TSLOT = uint256(keccak256("INIT_DATA_TSLOT")) - 1;

    /// -----------------------------------------------------------------------
    /// Immutable args
    /// -----------------------------------------------------------------------

    WETH internal immutable weth;
    IPermit2 internal immutable permit2;
    IPoolManager internal immutable poolManager;
    IBunniToken internal immutable bunniTokenImplementation;

    /// -----------------------------------------------------------
    /// Storage variables
    /// -----------------------------------------------------------

    /// @dev The storage content of BunniHub. Useful for passing storage to BunniHubLogic.
    HubStorage internal s;

    /// -----------------------------------------------------------
    /// Modifiers
    /// -----------------------------------------------------------

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert BunniHub__PastDeadline();
        _;
    }

    modifier notPaused(uint256 position) {
        (uint8 pauseFlags, bool unpauseFuse) = (s.pauseFlags, s.unpauseFuse);
        // pause function if bit is set in `pauseFlags` and `unpauseFuse` is false
        if (pauseFlags & (1 << position) != 0 && !unpauseFuse) revert BunniHub__Paused();
        _;
    }

    /// -----------------------------------------------------------
    /// Constructor
    /// -----------------------------------------------------------

    constructor(
        IPoolManager poolManager_,
        WETH weth_,
        IPermit2 permit2_,
        IBunniToken bunniTokenImplementation_,
        address initialOwner,
        IBunniHook[] memory initialHookWhitelist
    ) {
        require(
            address(permit2_) != address(0) && address(poolManager_) != address(0) && address(weth_) != address(0)
                && address(bunniTokenImplementation_) != address(0) && initialOwner != address(0)
        );
        weth = weth_;
        permit2 = permit2_;
        poolManager = poolManager_;
        bunniTokenImplementation = bunniTokenImplementation_;
        _initializeOwner(initialOwner);

        // set initial hook whitelist
        for (uint256 i; i < initialHookWhitelist.length; i++) {
            s.hookWhitelist[initialHookWhitelist[i]] = true;
            emit SetHookWhitelist(initialHookWhitelist[i], true);
        }
    }

    /// -----------------------------------------------------------
    /// External functions
    /// -----------------------------------------------------------

    /// @inheritdoc IBunniHub
    function deposit(DepositParams calldata params)
        external
        payable
        virtual
        override
        nonReentrant
        checkDeadline(params.deadline)
        notPaused(0)
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        return BunniHubLogic.deposit(
            s,
            BunniHubLogic.Env({
                weth: weth,
                permit2: permit2,
                poolManager: poolManager,
                bunniTokenImplementation: bunniTokenImplementation
            }),
            params
        );
    }

    /// @inheritdoc IBunniHub
    function queueWithdraw(QueueWithdrawParams calldata params) external virtual override nonReentrant notPaused(1) {
        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        PoolId id = params.poolKey.toId();
        IBunniToken bunniToken = _getBunniTokenOfPool(id);
        if (address(bunniToken) == address(0)) revert BunniHub__BunniTokenNotInitialized();

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        address msgSender = LibMulticaller.senderOrSigner();
        QueuedWithdrawal memory queued = s.queuedWithdrawals[id][msgSender];

        // update queued withdrawal
        // use unchecked to get unlockTimestamp to overflow back to 0 if overflow occurs
        // which is fine since we only care about relative time
        uint56 blockTimestamp = uint56(block.timestamp);
        uint56 newUnlockTimestamp;
        unchecked {
            newUnlockTimestamp = blockTimestamp + WITHDRAW_DELAY;
        }
        if (queued.shareAmount != 0) {
            // requeue expired queued withdrawal
            // if queued.unlockTimestamp + WITHDRAW_GRACE_PERIOD overflows it's fine to requeue
            // it's safe since the LP will still have to wait to withdraw
            unchecked {
                if (queued.unlockTimestamp + WITHDRAW_GRACE_PERIOD >= blockTimestamp) {
                    revert BunniHub__NoExpiredWithdrawal();
                }
            }
            s.queuedWithdrawals[id][msgSender].unlockTimestamp = newUnlockTimestamp;
        } else {
            // create new queued withdrawal
            if (params.shares == 0) revert BunniHub__ZeroInput();
            s.queuedWithdrawals[id][msgSender] =
                QueuedWithdrawal({shareAmount: params.shares, unlockTimestamp: newUnlockTimestamp});

            /// -----------------------------------------------------------------------
            /// External calls
            /// -----------------------------------------------------------------------

            // transfer shares from msgSender to address(this)
            bunniToken.transferFrom(msgSender, address(this), params.shares);
        }

        emit QueueWithdraw(msgSender, id, params.shares);
    }

    /// @inheritdoc IBunniHub
    function withdraw(WithdrawParams calldata params)
        external
        virtual
        override
        nonReentrant
        checkDeadline(params.deadline)
        notPaused(2)
        returns (uint256 amount0, uint256 amount1)
    {
        return BunniHubLogic.withdraw(
            s,
            BunniHubLogic.Env({
                weth: weth,
                permit2: permit2,
                poolManager: poolManager,
                bunniTokenImplementation: bunniTokenImplementation
            }),
            params
        );
    }

    /// @inheritdoc IBunniHub
    function deployBunniToken(DeployBunniTokenParams calldata params)
        external
        override
        nonReentrant
        notPaused(3)
        returns (IBunniToken token, PoolKey memory key)
    {
        return BunniHubLogic.deployBunniToken(
            s,
            BunniHubLogic.Env({
                weth: weth,
                permit2: permit2,
                poolManager: poolManager,
                bunniTokenImplementation: bunniTokenImplementation
            }),
            params
        );
    }

    /// @inheritdoc IBunniHub
    function hookHandleSwap(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 inputAmount,
        uint256 outputAmount,
        bool shouldSurge
    ) external override nonReentrant notPaused(4) {
        if (msg.sender != address(key.hooks)) revert BunniHub__Unauthorized();

        // load state
        PoolId poolId = key.toId();
        PoolState memory state = getPoolState(s, poolId);
        (Currency inputToken, Currency outputToken) =
            zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        (uint256 initialReserve0, uint256 initialReserve1) = (state.reserve0, state.reserve1);

        // pull input claim tokens from hook
        if (inputAmount != 0) {
            zeroForOne ? state.rawBalance0 += inputAmount : state.rawBalance1 += inputAmount;
            poolManager.transferFrom(address(key.hooks), address(this), inputToken.toId(), inputAmount);
        }

        // push output claim tokens to hook
        if (outputAmount != 0) {
            (uint256 outputRawBalance, ERC4626 outputVault) =
                zeroForOne ? (state.rawBalance1, state.vault1) : (state.rawBalance0, state.vault0);
            if (address(outputVault) != address(0) && outputRawBalance < outputAmount) {
                // insufficient token balance
                // withdraw tokens from reserves
                (int256 reserveChange, int256 rawBalanceChange) = _updateVaultReserveViaClaimTokens(
                    (outputAmount - outputRawBalance).toInt256(), outputToken, outputVault
                );
                zeroForOne
                    ? (state.reserve1, state.rawBalance1) =
                        (_updateBalance(state.reserve1, reserveChange), _updateBalance(state.rawBalance1, rawBalanceChange))
                    : (state.reserve0, state.rawBalance0) =
                        (_updateBalance(state.reserve0, reserveChange), _updateBalance(state.rawBalance0, rawBalanceChange));
            }
            zeroForOne ? state.rawBalance1 -= outputAmount : state.rawBalance0 -= outputAmount;
            poolManager.transfer(address(key.hooks), outputToken.toId(), outputAmount);
        }

        // update raw token balances if we're using vaults and the (rawBalance / balance) ratio is outside the bounds
        // skip depositing into vaults if we're surging since we need to use raw tokens for rebalancing anyways
        // skip withdrawing from vaults if we're surging as well since after receiving raw tokens from the rebalance order it may become unnecessary
        if (!shouldSurge) {
            if (address(state.vault0) != address(0)) {
                (state.reserve0, state.rawBalance0) = _updateRawBalanceIfNeeded(
                    key.currency0,
                    state.vault0,
                    state.rawBalance0,
                    state.reserve0,
                    state.minRawTokenRatio0,
                    state.maxRawTokenRatio0,
                    state.targetRawTokenRatio0
                );
            }
            if (address(state.vault1) != address(0)) {
                (state.reserve1, state.rawBalance1) = _updateRawBalanceIfNeeded(
                    key.currency1,
                    state.vault1,
                    state.rawBalance1,
                    state.reserve1,
                    state.minRawTokenRatio1,
                    state.maxRawTokenRatio1,
                    state.targetRawTokenRatio1
                );
            }
        }

        // update state
        s.poolState[poolId].rawBalance0 = state.rawBalance0;
        s.poolState[poolId].rawBalance1 = state.rawBalance1;
        if (address(state.vault0) != address(0) && initialReserve0 != state.reserve0) {
            s.reserve0[poolId] = state.reserve0;
        }
        if (address(state.vault1) != address(0) && initialReserve1 != state.reserve1) {
            s.reserve1[poolId] = state.reserve1;
        }
    }

    /// @inheritdoc IBunniHub
    function hookSetIdleBalance(PoolKey calldata key, IdleBalance newIdleBalance) external notPaused(5) {
        if (msg.sender != address(key.hooks)) revert BunniHub__Unauthorized();
        s.idleBalance[key.toId()] = newIdleBalance;
    }

    /// @inheritdoc IBunniHub
    function lockForRebalance(PoolKey calldata key) external notPaused(6) {
        if (address(_getBunniTokenOfPool(key.toId())) == address(0)) revert BunniHub__BunniTokenNotInitialized();
        if (msg.sender != address(key.hooks)) revert BunniHub__Unauthorized();
        _nonReentrantBefore();
    }

    /// @inheritdoc IBunniHub
    function hookGive(PoolKey calldata key, bool isCurrency0, uint256 amount) external override notPaused(7) {
        if (msg.sender != address(key.hooks)) revert BunniHub__Unauthorized();
        if (amount == 0) return; // no-op if amount is zero

        PoolId poolId = key.toId();

        // pull claim tokens from hook
        if (isCurrency0) {
            s.poolState[poolId].rawBalance0 += amount; // effect
            poolManager.transferFrom(address(key.hooks), address(this), key.currency0.toId(), amount); // interaction
        } else {
            s.poolState[poolId].rawBalance1 += amount; // effect
            poolManager.transferFrom(address(key.hooks), address(this), key.currency1.toId(), amount); // interaction
        }
    }

    receive() external payable {}

    /// -----------------------------------------------------------------------
    /// Owner functions
    /// -----------------------------------------------------------------------

    /// @inheritdoc IBunniHub
    function setPauser(address guy, bool status) external onlyOwner {
        s.isPauser[guy] = status;
        emit SetPauser(guy, status);
    }

    /// @inheritdoc IBunniHub
    function setPauseFlags(uint8 pauseFlags) external {
        // only owner or pauser can set pause flags
        if (msg.sender != owner() && !s.isPauser[msg.sender]) revert BunniHub__Unauthorized();

        s.pauseFlags = pauseFlags;
        emit SetPauseFlags(pauseFlags);
    }

    /// @inheritdoc IBunniHub
    function burnPauseFuse() external onlyOwner {
        s.unpauseFuse = true; // all functions are permanently unpaused
        emit BurnPauseFuse();
    }

    /// @inheritdoc IBunniHub
    function setHookWhitelist(IBunniHook hook, bool whitelisted) external onlyOwner {
        s.hookWhitelist[hook] = whitelisted;
        emit SetHookWhitelist(hook, whitelisted);
    }

    /// -----------------------------------------------------------------------
    /// View functions
    /// -----------------------------------------------------------------------

    /// @inheritdoc IBunniHub
    function poolState(PoolId poolId) external view returns (PoolState memory) {
        return getPoolState(s, poolId);
    }

    /// @inheritdoc IBunniHub
    function poolParams(PoolId poolId) external view returns (PoolState memory) {
        return getPoolParams(s.poolState[poolId].immutableParamsPointer);
    }

    /// @inheritdoc IBunniHub
    function bunniTokenOfPool(PoolId poolId) external view returns (IBunniToken) {
        return _getBunniTokenOfPool(poolId);
    }

    /// @inheritdoc IBunniHub
    function hookletOfPool(PoolId poolId) external view returns (IHooklet) {
        return _getHookletOfPool(poolId);
    }

    /// @inheritdoc IBunniHub
    function hookParams(PoolId poolId) external view returns (bytes memory) {
        return _getHookParams(poolId);
    }

    /// @inheritdoc IBunniHub
    function poolBalances(PoolId poolId) external view returns (uint256 balance0, uint256 balance1) {
        PoolState memory state = getPoolState(s, poolId);
        balance0 = state.rawBalance0 + getReservesInUnderlying(state.reserve0, state.vault0);
        balance1 = state.rawBalance1 + getReservesInUnderlying(state.reserve1, state.vault1);
    }

    /// @inheritdoc IBunniHub
    function idleBalance(PoolId poolId) external view returns (IdleBalance) {
        return s.idleBalance[poolId];
    }

    /// @inheritdoc IBunniHub
    function nonce(bytes32 bunniSubspace) external view override returns (uint24) {
        return s.nonce[bunniSubspace];
    }

    /// @inheritdoc IBunniHub
    function poolIdOfBunniToken(IBunniToken bunniToken) external view override returns (PoolId) {
        return s.poolIdOfBunniToken[bunniToken];
    }

    /// @inheritdoc IBunniHub
    function poolInitData() external view returns (bytes memory) {
        return INIT_DATA_TSLOT.tBytes().get();
    }

    /// @inheritdoc IBunniHub
    function isPauser(address guy) external view returns (bool) {
        return s.isPauser[guy];
    }

    /// @inheritdoc IBunniHub
    function getPauseStatus() external view returns (uint8 pauseFlags, bool unpauseFuse) {
        return (s.pauseFlags, s.unpauseFuse);
    }

    /// @inheritdoc IBunniHub
    function hookIsWhitelisted(IBunniHook hook) external view returns (bool) {
        return s.hookWhitelist[hook];
    }

    /// -----------------------------------------------------------------------
    /// Uniswap callback
    /// -----------------------------------------------------------------------

    enum UnlockCallbackType {
        DEPOSIT,
        WITHDRAW
    }

    struct DepositCallbackInputData {
        address user;
        PoolKey poolKey;
        uint256 msgValue;
        uint256 rawAmount0;
        uint256 rawAmount1;
    }

    struct WithdrawCallbackInputData {
        address user;
        PoolKey poolKey;
        uint256 rawAmount0;
        uint256 rawAmount1;
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        // verify sender
        if (msg.sender != address(poolManager)) revert BunniHub__Unauthorized();

        // decode input
        (UnlockCallbackType t, bytes memory callbackData) = abi.decode(data, (UnlockCallbackType, bytes));

        // redirect to respective callback
        if (t == UnlockCallbackType.DEPOSIT) {
            return _depositUnlockCallback(abi.decode(callbackData, (DepositCallbackInputData)));
        } else if (t == UnlockCallbackType.WITHDRAW) {
            _withdrawUnlockCallback(abi.decode(callbackData, (WithdrawCallbackInputData)));
        }
        // fallback
        return bytes("");
    }

    function _depositUnlockCallback(DepositCallbackInputData memory data) internal returns (bytes memory) {
        (address msgSender, PoolKey memory key, uint256 msgValue, uint256 rawAmount0, uint256 rawAmount1) =
            (data.user, data.poolKey, data.msgValue, data.rawAmount0, data.rawAmount1);

        PoolId poolId = key.toId();
        uint256 paid0;
        uint256 paid1;
        if (rawAmount0 != 0) {
            poolManager.sync(key.currency0);

            // transfer tokens to poolManager
            if (key.currency0.isAddressZero()) {
                if (msgValue < rawAmount0) revert BunniHub__MsgValueInsufficient();
                paid0 = poolManager.settle{value: rawAmount0}();
            } else {
                Currency.unwrap(key.currency0).excessivelySafeTransferFrom2(msgSender, address(poolManager), rawAmount0);
                paid0 = poolManager.settle();
            }

            poolManager.mint(address(this), key.currency0.toId(), paid0);
            s.poolState[poolId].rawBalance0 += paid0;
        }
        if (rawAmount1 != 0) {
            poolManager.sync(key.currency1);

            // transfer tokens to poolManager
            // currency1 can't be zero since it's > currency0
            Currency.unwrap(key.currency1).excessivelySafeTransferFrom2(msgSender, address(poolManager), rawAmount1);
            paid1 = poolManager.settle();

            poolManager.mint(address(this), key.currency1.toId(), paid1);
            s.poolState[poolId].rawBalance1 += paid1;
        }
        return abi.encode(paid0, paid1);
    }

    function _withdrawUnlockCallback(WithdrawCallbackInputData memory data) internal {
        (address recipient, PoolKey memory key, uint256 rawAmount0, uint256 rawAmount1) =
            (data.user, data.poolKey, data.rawAmount0, data.rawAmount1);

        PoolId poolId = key.toId();
        if (rawAmount0 != 0) {
            s.poolState[poolId].rawBalance0 -= rawAmount0;
            poolManager.burn(address(this), key.currency0.toId(), rawAmount0);
            poolManager.take(key.currency0, recipient, rawAmount0);
        }
        if (rawAmount1 != 0) {
            s.poolState[poolId].rawBalance1 -= rawAmount1;
            poolManager.burn(address(this), key.currency1.toId(), rawAmount1);
            poolManager.take(key.currency1, recipient, rawAmount1);
        }
    }

    /// -----------------------------------------------------------------------
    /// Internal utilities
    /// -----------------------------------------------------------------------

    /// @dev Deposits/withdraws tokens from a vault via claim tokens.
    /// @param rawBalanceChange The amount to deposit/withdraw. Positive for withdraw, negative for deposit.
    /// @param currency The currency to deposit/withdraw.
    /// @param vault The vault to deposit/withdraw from.
    /// @return reserveChange The change in reserves. Positive for deposit, negative for withdraw.
    /// @return actualRawBalanceChange The actual amount of raw tokens deposited/withdrawn. Positive for withdraw, negative for deposit.
    function _updateVaultReserveViaClaimTokens(int256 rawBalanceChange, Currency currency, ERC4626 vault)
        internal
        returns (int256 reserveChange, int256 actualRawBalanceChange)
    {
        uint256 absAmount = FixedPointMathLib.abs(rawBalanceChange);
        if (rawBalanceChange < 0) {
            uint256 maxDepositAmount = vault.maxDeposit(address(this));
            // if poolManager doesn't have enough tokens or we're trying to deposit more than the vault accepts
            // then we only deposit what we can
            // we're only maintaining the raw balance ratio so it's fine to deposit less than requested
            uint256 poolManagerReserve = currency.balanceOf(address(poolManager));
            absAmount = FixedPointMathLib.min(FixedPointMathLib.min(absAmount, maxDepositAmount), poolManagerReserve);

            // If the amount to deposit is zero, ignore the deposit execution
            if (absAmount == 0) return (0, 0);

            // burn claim tokens from this
            poolManager.burn(address(this), currency.toId(), absAmount);

            // take tokens from poolManager
            poolManager.take(currency, address(this), absAmount);

            // deposit tokens into vault
            IERC20 token;
            if (currency.isAddressZero()) {
                // wrap ETH
                weth.deposit{value: absAmount}();
                token = IERC20(address(weth));
            } else {
                token = IERC20(Currency.unwrap(currency));
            }
            uint256 tokenBalanceBefore = address(token).balanceOf(address(this));
            address(token).safeApproveWithRetry(address(vault), absAmount);
            reserveChange = vault.deposit(absAmount, address(this)).toInt256();

            // use actual deposited raw balance
            uint256 actualDepositedAmount = tokenBalanceBefore - address(token).balanceOf(address(this));
            if (actualDepositedAmount > absAmount) {
                // somehow lost more tokens than requested
                // this should never happen unless something is seriously wrong
                revert BunniHub__VaultTookMoreThanRequested();
            }
            actualRawBalanceChange = -actualDepositedAmount.toInt256();

            if (actualDepositedAmount != absAmount) {
                // revoke token approval to vault
                address(token).safeApprove(address(vault), 0);

                // deposit excess amount back into PoolManager as claim tokens
                uint256 excessAmount = absAmount - actualDepositedAmount;
                poolManager.sync(currency); // sync poolManager balance before transferring assets to it
                if (currency.isAddressZero()) {
                    // unwrap WETH and settle using ETH
                    weth.withdraw(excessAmount);
                    poolManager.settle{value: excessAmount}();
                } else {
                    currency.transfer(address(poolManager), excessAmount);
                    excessAmount = poolManager.settle(); // use actual settled amount in case of transfer tax
                }
                poolManager.mint(address(this), currency.toId(), excessAmount);
            }
        } else if (rawBalanceChange > 0) {
            // sync poolManager balance before transferring assets to it
            poolManager.sync(currency);

            uint256 settleMsgValue;
            if (currency.isAddressZero()) {
                // withdraw WETH from vault to address(this)
                reserveChange = -vault.withdraw(absAmount, address(this), address(this)).toInt256();

                // burn WETH for ETH
                weth.withdraw(absAmount);

                // transfer ETH to poolManager
                settleMsgValue = absAmount;
            } else {
                // normal ERC20
                // withdraw tokens to poolManager
                reserveChange = -vault.withdraw(absAmount, address(poolManager), address(this)).toInt256();
            }

            // settle with poolManager
            // check actual settled amount to prevent malicious vaults from giving us less than we asked for
            uint256 settleAmount = poolManager.settle{value: settleMsgValue}();
            actualRawBalanceChange = settleAmount.toInt256();

            // mint claim tokens to this
            poolManager.mint(address(this), currency.toId(), settleAmount);
        }
    }

    /// @dev Uses the reserve to update the raw balance so that the (rawBalance / balance) ratio is within bounds.
    function _updateRawBalanceIfNeeded(
        Currency currency,
        ERC4626 vault,
        uint256 rawBalance,
        uint256 reserve,
        uint256 minRatio,
        uint256 maxRatio,
        uint256 targetRatio
    ) internal returns (uint256 newReserve, uint256 newRawBalance) {
        uint256 balance = rawBalance + getReservesInUnderlying(reserve, vault);
        uint256 minRawBalance = balance.mulDiv(minRatio, RAW_TOKEN_RATIO_BASE);
        uint256 maxRawBalance = balance.mulDiv(maxRatio, RAW_TOKEN_RATIO_BASE);

        if (rawBalance < minRawBalance || rawBalance > maxRawBalance) {
            uint256 targetRawBalance = balance.mulDiv(targetRatio, RAW_TOKEN_RATIO_BASE);
            (int256 reserveChange, int256 rawBalanceChange) =
                _updateVaultReserveViaClaimTokens(targetRawBalance.toInt256() - rawBalance.toInt256(), currency, vault);
            newReserve = _updateBalance(reserve, reserveChange);
            newRawBalance = _updateBalance(rawBalance, rawBalanceChange);
        } else {
            (newReserve, newRawBalance) = (reserve, rawBalance);
        }
    }

    function _getBunniTokenOfPool(PoolId poolId) internal view returns (IBunniToken bunniToken) {
        address ptr = s.poolState[poolId].immutableParamsPointer;
        if (ptr == address(0)) return IBunniToken(address(0));
        bytes memory rawValue = ptr.read({start: 20, end: 40});
        bunniToken = IBunniToken(address(bytes20(rawValue)));
    }

    function _getHookletOfPool(PoolId poolId) internal view returns (IHooklet hooklet) {
        address ptr = s.poolState[poolId].immutableParamsPointer;
        if (ptr == address(0)) return IHooklet(address(0));
        bytes memory rawValue = ptr.read({start: 134, end: 154});
        hooklet = IHooklet(address(bytes20(rawValue)));
    }

    function _getHookParams(PoolId poolId) internal view returns (bytes memory result) {
        address ptr = s.poolState[poolId].immutableParamsPointer;
        if (ptr == address(0)) return bytes("");
        result = ptr.read({start: 160});
    }

    function _updateBalance(uint256 balance, int256 delta) internal pure returns (uint256) {
        return (balance.toInt256() + delta).toUint256();
    }
}
