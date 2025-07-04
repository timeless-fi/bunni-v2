// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import "@uniswap/v4-core/src/types/PoolId.sol";
import "@uniswap/v4-core/src/types/Currency.sol";
import "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Extsload} from "@uniswap/v4-core/src/Extsload.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

import {AmAmm} from "biddog/AmAmm.sol";

import "flood-contracts/src/interfaces/IZone.sol";
import "flood-contracts/src/interfaces/IFloodPlain.sol";

import {LibMulticaller} from "multicaller/LibMulticaller.sol";

import {IERC1271} from "permit2/src/interfaces/IERC1271.sol";

import {WETH} from "solady/tokens/WETH.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import "./lib/Math.sol";
import "./base/Errors.sol";
import "./base/Constants.sol";
import "./lib/AmAmmPayload.sol";
import "./types/IdleBalance.sol";
import "./base/SharedStructs.sol";
import "./interfaces/IBunniHook.sol";
import {Oracle} from "./lib/Oracle.sol";
import {Ownable} from "./base/Ownable.sol";
import {BaseHook} from "./base/BaseHook.sol";
import {HookletLib} from "./lib/HookletLib.sol";
import {IHooklet} from "./interfaces/IHooklet.sol";
import {IBunniHub} from "./interfaces/IBunniHub.sol";
import {BunniSwapMath} from "./lib/BunniSwapMath.sol";
import {BlockNumberLib} from "./lib/BlockNumberLib.sol";
import {BunniHookLogic} from "./lib/BunniHookLogic.sol";
import {ReentrancyGuard} from "./base/ReentrancyGuard.sol";

/// @title BunniHook
/// @author zefram.eth
/// @notice Uniswap v4 hook responsible for handling swaps on Bunni. Implements auto-rebalancing
/// executed via FloodPlain. Uses am-AMM to recapture LVR & MEV.
contract BunniHook is BaseHook, Ownable, IBunniHook, ReentrancyGuard, AmAmm, Extsload {
    /// -----------------------------------------------------------------------
    /// Library usage
    /// -----------------------------------------------------------------------

    using SafeTransferLib for *;
    using FixedPointMathLib for *;
    using HookletLib for IHooklet;
    using IdleBalanceLibrary for *;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;
    using Oracle for Oracle.Observation[MAX_CARDINALITY];

    /// -----------------------------------------------------------------------
    /// Immutable args
    /// -----------------------------------------------------------------------

    WETH internal immutable weth;
    IBunniHub internal immutable hub;
    address internal immutable permit2;
    IFloodPlain internal immutable floodPlain;

    /// -----------------------------------------------------------------------
    /// Transient storage variables
    /// -----------------------------------------------------------------------

    /// @dev Equal to uint256(keccak256("REBALANCE_OUTPUT_BALANCE_SLOT")) - 1
    uint256 internal constant REBALANCE_OUTPUT_BALANCE_SLOT =
        0x07bd55ea91cddb9c2c27beeba6deadeb8f557caeb242f82d756cf1d33154a78c;

    /// @dev Equal to uint256(keccak256("REBALANCE_ACTIVE_SLOT")) - 1
    uint256 internal constant REBALANCE_ACTIVE_SLOT = 0x81033a18d648f105cf4834b06051c94a8095dbf3ba7aa3cb9e7baead1658f20a;

    /// -----------------------------------------------------------------------
    /// Storage variables
    /// -----------------------------------------------------------------------

    /// @dev Contains mappings used by both BunniHook and BunniLogic. Makes passing
    /// mappings to BunniHookLogic easier & cheaper.
    HookStorage internal s;

    /// @dev The address that receives the hook protocol fees
    address internal hookFeeRecipient;

    /// @notice Used for computing the hook fee amount. Fee taken is `amount * swapFee / 1e6 * hookFeesModifier / 1e6`.
    uint32 internal hookFeeModifier;

    /// @notice The FloodZone contract used in rebalance orders.
    IZone internal floodZone;

    /// @dev canWithdraw() returns false when a rebalance order is active. If rebalance orders don't get filled, withdrawals
    /// will continue to be blocked until the rebalance order is fulfilled since there is order resubmission. This allows
    /// the hook owner to manually unblock withdrawals for a pool.
    mapping(PoolId => bool) internal withdrawalUnblocked;

    /// @notice The K constant used in am-AMM.
    uint48 internal _K;

    /// @notice The pending K constant used in am-AMM. Used when scheduling a K change.
    uint48 internal _pendingK;

    /// @notice The block number at which the pending K change will take effect.
    /// @dev Don't have to worry about overflow since it would take 4.63e34 years to occur (at 0.001ms block time)
    uint160 internal _pendingKActiveBlock;

    /// @dev The address with the right to permanently set the hook fee recipient.
    /// Immutable, but put in storage to reduce bytecode size.
    address internal hookFeeRecipientController;

    /// @dev The Unix timestamp in seconds when this contract was deployed.
    /// Immutable, but put in storage to reduce bytecode size.
    uint256 internal deployTimestamp;

    /// -----------------------------------------------------------------------
    /// Modifiers
    /// -----------------------------------------------------------------------

    modifier onlyCurator(PoolId id) {
        _checkOnlyCurator(id);
        _;
    }

    /// -----------------------------------------------------------------------
    /// Constructor
    /// -----------------------------------------------------------------------

    constructor(
        IPoolManager poolManager_,
        IBunniHub hub_,
        IFloodPlain floodPlain_,
        WETH weth_,
        IZone floodZone_,
        address owner_,
        address hookFeeRecipientController_,
        uint48 k_
    ) BaseHook(poolManager_) {
        hub = hub_;
        floodPlain = floodPlain_;
        permit2 = address(floodPlain_.PERMIT2());
        weth = weth_;
        require(
            address(hub_) != address(0) && address(floodPlain_) != address(0) && address(permit2) != address(0)
                && address(weth_) != address(0) && hookFeeRecipientController_ != address(0) && owner_ != address(0)
                && k_ != 0
        );

        floodZone = floodZone_;
        _K = k_;
        deployTimestamp = block.timestamp;
        hookFeeRecipientController = hookFeeRecipientController_;

        _initializeOwner(owner_);
        poolManager_.setOperator(address(hub_), true);
    }

    /// -----------------------------------------------------------------------
    /// EIP-1271 compliance
    /// -----------------------------------------------------------------------

    /// @inheritdoc IERC1271
    function isValidSignature(bytes32 hash, bytes memory signature)
        external
        view
        override
        returns (bytes4 magicValue)
    {
        // verify rebalance order
        PoolId id = abi.decode(signature, (PoolId)); // we use the signature field to store the pool id
        if (s.rebalanceOrderPermit2Hash[id] == hash) {
            return this.isValidSignature.selector;
        }
    }

    /// -----------------------------------------------------------------------
    /// External functions
    /// -----------------------------------------------------------------------

    /// @inheritdoc IBunniHook
    function increaseCardinalityNext(PoolKey calldata key, uint32 cardinalityNext)
        public
        override
        returns (uint32 cardinalityNextOld, uint32 cardinalityNextNew)
    {
        PoolId id = key.toId();

        ObservationState storage state = s.states[id];

        cardinalityNextOld = state.cardinalityNext;
        cardinalityNextNew = s.observations[id].grow(cardinalityNextOld, cardinalityNext);
        state.cardinalityNext = cardinalityNextNew;
    }

    /// @inheritdoc IBunniHook
    function claimProtocolFees(Currency[] calldata currencyList)
        external
        override
        nonReentrant
        returns (uint256[] memory claimedAmounts)
    {
        return abi.decode(
            poolManager.unlock(abi.encode(HookUnlockCallbackType.CLAIM_FEES, abi.encode(currencyList))), (uint256[])
        );
    }

    receive() external payable {}

    /// -----------------------------------------------------------------------
    /// Uniswap lock callback
    /// -----------------------------------------------------------------------

    enum HookUnlockCallbackType {
        REBALANCE_PREHOOK,
        REBALANCE_POSTHOOK,
        CLAIM_FEES,
        CURATOR_CLAIM_FEES
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override poolManagerOnly returns (bytes memory) {
        // decode input
        (HookUnlockCallbackType t, bytes memory callbackData) = abi.decode(data, (HookUnlockCallbackType, bytes));

        if (t == HookUnlockCallbackType.REBALANCE_PREHOOK) {
            (Currency currency, uint256 amount, PoolKey memory key, bool zeroForOne) =
                abi.decode(callbackData, (Currency, uint256, PoolKey, bool));
            _rebalanceHookCallback(true, currency, amount, key, zeroForOne);
        } else if (t == HookUnlockCallbackType.REBALANCE_POSTHOOK) {
            (Currency currency, uint256 amount, PoolKey memory key, bool zeroForOne) =
                abi.decode(callbackData, (Currency, uint256, PoolKey, bool));
            _rebalanceHookCallback(false, currency, amount, key, zeroForOne);
        } else if (t == HookUnlockCallbackType.CLAIM_FEES) {
            // claim protocol fees
            return _claimFees(callbackData);
        } else if (t == HookUnlockCallbackType.CURATOR_CLAIM_FEES) {
            _curatorClaimFees(callbackData);
        }
        return bytes("");
    }

    /// @dev Prehook calls hub.hookHandleSwap to pull the rebalance swap input tokens from BunniHub.
    /// Then burns PoolManager claim tokens and takes the underlying tokens from PoolManager.
    /// Posthook Settles tokens sent to PoolManager and mints the corresponding claim tokens.
    /// Then calls hub.hookGive to update pool balances with rebalance swap output.
    /// Used while executing rebalance orders.
    function _rebalanceHookCallback(
        bool isPreHook,
        Currency currency,
        uint256 amount,
        PoolKey memory key,
        bool zeroForOne
    ) internal {
        if (isPreHook) {
            // pull claim tokens from BunniHub
            hub.hookHandleSwap({
                key: key,
                zeroForOne: zeroForOne,
                inputAmount: 0,
                outputAmount: amount,
                shouldSurge: false
            });

            // lock BunniHub to prevent reentrancy
            hub.lockForRebalance(key);

            // burn and take
            poolManager.burn(address(this), currency.toId(), amount);
            poolManager.take(currency, address(this), amount);

            // approve input token to permit2
            ERC20 token = currency.isAddressZero() ? weth : ERC20(Currency.unwrap(currency));
            if (token.allowance(address(this), permit2) < amount) {
                address(token).safeApproveWithRetry(permit2, amount);
            }
        } else {
            // sync poolManager balance and transfer the output tokens to poolManager
            poolManager.sync(currency);
            if (!currency.isAddressZero()) {
                Currency.unwrap(currency).safeTransfer(address(poolManager), amount);
            }

            // settle the transferred tokens and mint claim tokens
            uint256 paid = poolManager.settle{value: currency.isAddressZero() ? amount : 0}();
            poolManager.mint(address(this), currency.toId(), paid);

            // push claim tokens to BunniHub
            hub.hookGive({key: key, isCurrency0: zeroForOne, amount: paid});
        }
    }

    /// @dev Claims protocol fees earned and sends it to the recipient.
    function _claimFees(bytes memory callbackData) internal returns (bytes memory) {
        // decode data
        Currency[] memory currencyList = abi.decode(callbackData, (Currency[]));
        address recipient = hookFeeRecipient;

        if (recipient == address(0)) revert BunniHook__HookFeeRecipientNotSet();

        uint256[] memory claimedAmounts = new uint256[](currencyList.length);

        // claim protocol fees
        for (uint256 i; i < currencyList.length; i++) {
            Currency currency = currencyList[i];
            // can claim balance - am-AMM accrued fees
            uint256 balance = poolManager.balanceOf(address(this), currency.toId()) - _totalFees[currency]
                - s.totalCuratorFees[currency];
            if (balance != 0) {
                poolManager.burn(address(this), currency.toId(), balance);
                if (currency.isAddressZero()) {
                    // convert ETH to WETH and send to recipient
                    poolManager.take(currency, address(this), balance);
                    weth.deposit{value: balance}();
                    weth.transfer(recipient, balance);
                } else {
                    // take tokens directly to recipient
                    poolManager.take(currency, recipient, balance);
                }
                claimedAmounts[i] = balance;
            }
        }

        emit ClaimProtocolFees(currencyList, recipient);

        return abi.encode(claimedAmounts);
    }

    function _curatorClaimFees(bytes memory callbackData) internal {
        // decode data
        (PoolKey memory key, address recipient) = abi.decode(callbackData, (PoolKey, address));
        PoolId id = key.toId();

        // reset fees
        CuratorFees memory curatorFees = s.curatorFees[id];
        uint256 feeAmount0 = curatorFees.accruedFee0;
        uint256 feeAmount1 = curatorFees.accruedFee1;
        delete s.curatorFees[id].accruedFee0;
        delete s.curatorFees[id].accruedFee1;
        s.totalCuratorFees[key.currency0] -= feeAmount0;
        s.totalCuratorFees[key.currency1] -= feeAmount1;

        // claim fees
        if (feeAmount0 != 0) {
            poolManager.burn(address(this), key.currency0.toId(), feeAmount0);
            poolManager.take(key.currency0, recipient, feeAmount0);
        }
        if (feeAmount1 != 0) {
            poolManager.burn(address(this), key.currency1.toId(), feeAmount1);
            poolManager.take(key.currency1, recipient, feeAmount1);
        }

        emit CuratorClaimFees(id, recipient, feeAmount0, feeAmount1);
    }

    /// -----------------------------------------------------------------------
    /// BunniHub functions
    /// -----------------------------------------------------------------------

    /// @inheritdoc IBunniHook
    function updateLdfState(PoolId id, bytes32 newState) external override {
        if (msg.sender != address(hub)) revert BunniHook__Unauthorized();

        s.ldfStates[id] = newState;
    }

    /// -----------------------------------------------------------------------
    /// Owner functions
    /// -----------------------------------------------------------------------

    /// @inheritdoc IBunniHook
    function setZone(IZone zone) external onlyOwner {
        floodZone = zone;
        emit SetZone(zone);
    }

    /// @inheritdoc IBunniHook
    function setHookFeeRecipient(address newHookFeeRecipient) external {
        // hook recipient is set by the controller instead of the owner
        // but owner can set it 180 days after contract deployment if it hasn't been set already
        if (
            !(
                msg.sender == hookFeeRecipientController
                    || (msg.sender == owner() && block.timestamp >= deployTimestamp + 180 days)
            )
        ) revert BunniHook__Unauthorized();

        // hook recipient can only be set once
        if (hookFeeRecipient != address(0)) revert BunniHook__HookFeeRecipientAlreadySet();

        hookFeeRecipient = newHookFeeRecipient;
        emit SetHookFeeRecipient(newHookFeeRecipient);
    }

    /// @inheritdoc IBunniHook
    function setHookFeeModifier(uint32 newHookFeeModifier) external onlyOwner {
        // hook fee can't be turned off once turned on, and cannot exceed 50% and cannot be less than 10%
        if (newHookFeeModifier > MODIFIER_BASE / 2 || newHookFeeModifier < MODIFIER_BASE / 10) {
            revert BunniHook__InvalidModifier();
        }
        // hook fee can only be turned on if hook fee recipient is set
        if (hookFeeRecipient == address(0)) {
            revert BunniHook__HookFeeRecipientNotSet();
        }

        hookFeeModifier = newHookFeeModifier;

        emit SetHookFeeModifier(newHookFeeModifier);
    }

    /// @inheritdoc IBunniHook
    function setWithdrawalUnblocked(PoolId id, bool unblocked) external onlyOwner {
        withdrawalUnblocked[id] = unblocked;
        emit SetWithdrawalUnblocked(id, unblocked);
    }

    /// @inheritdoc IBunniHook
    function scheduleKChange(uint48 newK, uint160 activeBlock) external onlyOwner {
        // load storage vars from single slot
        uint48 k = _K;
        uint48 pendingK = _pendingK;
        uint160 pendingKActiveBlock = _pendingKActiveBlock;

        // validate input
        if (newK <= k) revert BunniHook__InvalidK();
        uint256 blockNumber = BlockNumberLib.getBlockNumber();
        if (activeBlock < blockNumber) revert BunniHook__InvalidActiveBlock();

        // determine current K
        uint48 currentK = pendingK > k && blockNumber >= pendingKActiveBlock ? pendingK : k;

        if (currentK == k) {
            _pendingK = newK;
            _pendingKActiveBlock = activeBlock;
        } else {
            _K = currentK;
            _pendingK = newK;
            _pendingKActiveBlock = activeBlock;
        }
        emit ScheduleKChange(currentK, newK, activeBlock);
    }

    /// -----------------------------------------------------------------------
    /// Curator functions
    /// -----------------------------------------------------------------------

    /// @inheritdoc IBunniHook
    function curatorSetFeeRate(PoolId id, uint16 newFeeRate) external nonReentrant onlyCurator(id) {
        if (newFeeRate > MAX_CURATOR_FEE) revert BunniHook__InvalidCuratorFee();
        s.curatorFees[id].feeRate = newFeeRate;
        emit CuratorSetFeeRate(id, newFeeRate);
    }

    /// @inheritdoc IBunniHook
    function curatorClaimFees(PoolKey calldata key, address recipient) external nonReentrant onlyCurator(key.toId()) {
        poolManager.unlock(abi.encode(HookUnlockCallbackType.CURATOR_CLAIM_FEES, abi.encode(key, recipient)));
    }

    /// -----------------------------------------------------------------------
    /// View functions
    /// -----------------------------------------------------------------------

    /// @inheritdoc IBunniHook
    function observe(PoolKey calldata key, uint32[] calldata secondsAgos)
        external
        view
        override
        returns (int56[] memory tickCumulatives)
    {
        return BunniHookLogic.observe(s, key, secondsAgos);
    }

    /// @inheritdoc IBunniHook
    function isValidParams(bytes calldata hookParams) external pure override returns (bool) {
        return BunniHookLogic.isValidParams(hookParams);
    }

    /// @inheritdoc IBunniHook
    function getAmAmmEnabled(PoolId id) external view override returns (bool) {
        return _amAmmEnabled(id);
    }

    /// @inheritdoc IBunniHook
    function ldfStates(PoolId id) external view returns (bytes32) {
        return s.ldfStates[id];
    }

    /// @inheritdoc IBunniHook
    function slot0s(PoolId id)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint32 lastSwapTimestamp, uint32 lastSurgeTimestamp)
    {
        Slot0 memory slot0 = s.slot0s[id];
        return (slot0.sqrtPriceX96, slot0.tick, slot0.lastSwapTimestamp, slot0.lastSurgeTimestamp);
    }

    /// @inheritdoc IBunniHook
    function canWithdraw(PoolId id) external view returns (bool) {
        return block.timestamp > s.rebalanceOrderDeadline[id] || withdrawalUnblocked[id];
    }

    /// -----------------------------------------------------------------------
    /// Hooks
    /// -----------------------------------------------------------------------

    /// @inheritdoc IBaseHook
    function afterInitialize(address caller, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        external
        override(BaseHook, IBaseHook)
        poolManagerOnly
        returns (bytes4)
    {
        BunniHookLogic.afterInitialize(s, caller, key, sqrtPriceX96, tick, hub);
        return BunniHook.afterInitialize.selector;
    }

    /// @inheritdoc IBaseHook
    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override(BaseHook, IBaseHook)
        poolManagerOnly
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (
            bool useAmAmmFee,
            address amAmmManager,
            Currency amAmmFeeCurrency,
            uint256 amAmmFeeAmount,
            BeforeSwapDelta beforeSwapDelta
        ) = BunniHookLogic.beforeSwap(
            s,
            BunniHookLogic.Env({
                hookFeeModifier: hookFeeModifier,
                floodZone: floodZone,
                hub: hub,
                poolManager: poolManager,
                floodPlain: floodPlain,
                weth: weth,
                permit2: permit2
            }),
            sender,
            key,
            params
        );

        // accrue swap fee to the am-AMM manager if present
        if (useAmAmmFee) {
            _accrueFees(amAmmManager, amAmmFeeCurrency, amAmmFeeAmount);
        }

        return (BunniHook.beforeSwap.selector, beforeSwapDelta, 0);
    }

    /// -----------------------------------------------------------------------
    /// Rebalancing functions
    /// -----------------------------------------------------------------------

    /// @inheritdoc IBunniHook
    function rebalanceOrderHook(bool isPreHook, RebalanceOrderHookArgs calldata hookArgs)
        external
        override
        nonReentrant
    {
        // verify call came from Flood
        if (msg.sender != address(floodPlain)) {
            revert BunniHook__Unauthorized();
        }

        PoolId id = hookArgs.key.toId();

        // verify the order hash originated from BunniHook
        // this also verifies hookArgs is valid since it's hashed into the order hash
        bytes32 orderHash;
        // orderHash = bytes32(msg.data[msg.data.length - 32:msg.data.length]);
        assembly ("memory-safe") {
            orderHash := calldataload(sub(calldatasize(), 32))
        }
        if (s.rebalanceOrderHash[id] != orderHash) {
            revert BunniHook__InvalidRebalanceOrderHash();
        }

        if (isPreHook) {
            // mark the rebalance as active
            assembly ("memory-safe") {
                tstore(REBALANCE_ACTIVE_SLOT, 1)
            }

            RebalanceOrderPreHookArgs calldata args = hookArgs.preHookArgs;

            // cache the order input balance before the order execution
            uint256 inputBalanceBefore = args.currency.balanceOfSelf();

            // store the order output balance before the order execution in transient storage
            // this is used to compute the order output amount
            uint256 outputBalanceBefore = hookArgs.postHookArgs.currency.isAddressZero()
                ? weth.balanceOf(address(this))
                : hookArgs.postHookArgs.currency.balanceOfSelf();
            assembly ("memory-safe") {
                tstore(REBALANCE_OUTPUT_BALANCE_SLOT, outputBalanceBefore)
            }

            // pull input tokens from BunniHub to BunniHook
            // received in the form of PoolManager claim tokens
            // then unwrap claim tokens
            if (poolManager.isUnlocked()) {
                _rebalanceHookCallback(
                    true, args.currency, args.amount, hookArgs.key, hookArgs.key.currency1 == args.currency
                );
            } else {
                poolManager.unlock(
                    abi.encode(
                        HookUnlockCallbackType.REBALANCE_PREHOOK,
                        abi.encode(args.currency, args.amount, hookArgs.key, hookArgs.key.currency1 == args.currency)
                    )
                );
            }

            // ensure we received at least args.amount tokens so that there is enough input for the order
            if (args.currency.balanceOfSelf() - inputBalanceBefore < args.amount) {
                revert BunniHook__PrehookPostConditionFailed();
            }

            // wrap native ETH input to WETH
            // we're implicitly trusting the WETH contract won't charge a fee which is OK in practice
            if (args.currency.isAddressZero()) {
                weth.deposit{value: args.amount}();
            }
        } else {
            // invalidate the rebalance order
            delete s.rebalanceOrderHash[id];
            delete s.rebalanceOrderPermit2Hash[id];
            delete s.rebalanceOrderDeadline[id];

            // surge fee should be applied after the rebalance has been executed
            // since totalLiquidity will be increased
            // no need to check surgeFeeAutostartThreshold since we just increased the liquidity in this tx
            // so block.timestamp is the exact time when the surge should occur
            s.slot0s[id].lastSwapTimestamp = uint32(block.timestamp);
            s.slot0s[id].lastSurgeTimestamp = uint32(block.timestamp);

            RebalanceOrderPostHookArgs calldata args = hookArgs.postHookArgs;

            // compute order output amount by computing the difference in the output token balance
            uint256 orderOutputAmount;
            uint256 outputBalanceBefore;
            assembly ("memory-safe") {
                outputBalanceBefore := tload(REBALANCE_OUTPUT_BALANCE_SLOT)
            }
            if (args.currency.isAddressZero()) {
                // unwrap WETH output to native ETH
                orderOutputAmount = weth.balanceOf(address(this));
                weth.withdraw(orderOutputAmount);
            } else {
                orderOutputAmount = args.currency.balanceOfSelf();
            }
            orderOutputAmount -= outputBalanceBefore;

            // posthook should wrap output tokens as claim tokens and push it from BunniHook to BunniHub and update pool balances
            if (poolManager.isUnlocked()) {
                _rebalanceHookCallback(
                    false, args.currency, orderOutputAmount, hookArgs.key, hookArgs.key.currency0 == args.currency
                );
            } else {
                poolManager.unlock(
                    abi.encode(
                        HookUnlockCallbackType.REBALANCE_POSTHOOK,
                        abi.encode(
                            args.currency, orderOutputAmount, hookArgs.key, hookArgs.key.currency0 == args.currency
                        )
                    )
                );
            }

            // recompute idle balance
            BunniHookLogic.recomputeIdleBalance(s, hub, hookArgs.key);

            // call hooklet
            IHooklet hooklet = hub.hookletOfPool(id);
            hooklet.hookletAfterRebalance({
                sender: msg.sender,
                key: hookArgs.key,
                orderOutputIsCurrency0: hookArgs.key.currency0 == args.currency,
                orderInputAmount: hookArgs.preHookArgs.amount,
                orderOutputAmount: orderOutputAmount
            });

            // mark the rebalance as inactive
            assembly ("memory-safe") {
                tstore(REBALANCE_ACTIVE_SLOT, 0)
            }
        }
    }

    /// -----------------------------------------------------------------------
    /// AmAmm support
    /// -----------------------------------------------------------------------

    modifier notDuringRebalance() {
        _checkNotDuringRebalance();
        _;
    }

    function _checkNotDuringRebalance() internal view {
        uint256 rebalanceActive;
        assembly ("memory-safe") {
            rebalanceActive := tload(REBALANCE_ACTIVE_SLOT)
        }
        if (rebalanceActive != 0) revert BunniHook__RebalanceInProgress();
    }

    /// @inheritdoc IAmAmm
    function bid(PoolId id, address manager, bytes6 payload, uint128 rent, uint128 deposit)
        public
        virtual
        override(AmAmm, IAmAmm)
        nonReentrant
        notDuringRebalance
    {
        super.bid(id, manager, payload, rent, deposit);
    }

    /// @inheritdoc IAmAmm
    function depositIntoBid(PoolId id, uint128 amount, bool isTopBid)
        public
        virtual
        override(AmAmm, IAmAmm)
        nonReentrant
        notDuringRebalance
    {
        super.depositIntoBid(id, amount, isTopBid);
    }

    /// @inheritdoc IAmAmm
    function withdrawFromBid(PoolId id, uint128 amount, address recipient, bool isTopBid)
        public
        virtual
        override(AmAmm, IAmAmm)
        nonReentrant
        notDuringRebalance
    {
        super.withdrawFromBid(id, amount, recipient, isTopBid);
    }

    /// @inheritdoc IAmAmm
    function claimRefund(PoolId id, address recipient)
        public
        virtual
        override(AmAmm, IAmAmm)
        nonReentrant
        notDuringRebalance
        returns (uint256 refund)
    {
        return super.claimRefund(id, recipient);
    }

    /// @inheritdoc IAmAmm
    function claimFees(Currency currency, address recipient)
        public
        virtual
        override(AmAmm, IAmAmm)
        nonReentrant
        notDuringRebalance
        returns (uint256 fees)
    {
        return super.claimFees(currency, recipient);
    }

    /// @inheritdoc IAmAmm
    function increaseBidRent(
        PoolId id,
        uint128 additionalRent,
        uint128 updatedDeposit,
        bool isTopBid,
        address withdrawRecipient
    )
        public
        virtual
        override(AmAmm, IAmAmm)
        nonReentrant
        notDuringRebalance
        returns (uint128 amountDeposited, uint128 amountWithdrawn)
    {
        return super.increaseBidRent(id, additionalRent, updatedDeposit, isTopBid, withdrawRecipient);
    }

    function K(PoolId) internal view virtual override returns (uint48) {
        // load storage vars from single slot
        uint48 k = _K;
        uint48 pendingK = _pendingK;
        uint160 pendingKActiveBlock = _pendingKActiveBlock;

        // determine K value to use
        return pendingK > k && block.number >= pendingKActiveBlock ? pendingK : k;
    }

    function MIN_RENT(PoolId id) internal view virtual override returns (uint128) {
        // minimum rent should be propotional to the pool's BunniToken total supply
        bytes memory hookParams = hub.hookParams(id);
        bytes32 secondWord;
        /// @solidity memory-safe-assembly
        assembly {
            secondWord := mload(add(hookParams, 64))
        }
        uint48 minRentMultiplier = uint48(bytes6(secondWord << 32));
        uint256 minRent = hub.bunniTokenOfPool(id).totalSupply().mulWadUp(minRentMultiplier);

        // if the min rent value is somehow more than uint128.max, cap it to uint128.max
        return minRent > type(uint128).max ? type(uint128).max : uint128(minRent);
    }

    function _amAmmEnabled(PoolId id) internal view virtual override returns (bool) {
        return uint8(bytes1(_getHookParamsFirstWord(id) << 248)) != 0;
    }

    function _payloadIsValid(PoolId id, bytes6 payload) internal view virtual override returns (bool) {
        // use feeMax from hookParams
        bytes32 firstWord = _getHookParamsFirstWord(id);
        uint24 maxAmAmmFee = uint24(bytes3(firstWord << 96));

        // payload is valid if swapFee0For1 and swapFee1For0 are at most maxAmAmmFee
        (uint24 swapFee0For1, uint24 swapFee1For0) = decodeAmAmmPayload(payload);
        return swapFee0For1 <= maxAmAmmFee && swapFee1For0 <= maxAmAmmFee;
    }

    function _burnBidToken(PoolId id, uint256 amount) internal virtual override {
        hub.bunniTokenOfPool(id).burn(amount);
    }

    function _pullBidToken(PoolId id, address from, uint256 amount) internal virtual override {
        hub.bunniTokenOfPool(id).transferFrom(from, address(this), amount);
    }

    function _pushBidToken(PoolId id, address to, uint256 amount) internal virtual override {
        hub.bunniTokenOfPool(id).transfer(to, amount);
    }

    function _transferFeeToken(Currency currency, address to, uint256 amount) internal virtual override {
        poolManager.transfer(to, currency.toId(), amount);
    }

    function _getHookParamsFirstWord(PoolId id) internal view returns (bytes32 firstWord) {
        bytes memory hookParams = hub.hookParams(id);
        /// @solidity memory-safe-assembly
        assembly {
            firstWord := mload(add(hookParams, 32))
        }
    }

    function _checkOnlyCurator(PoolId id) internal view {
        address msgSender = LibMulticaller.senderOrSigner();
        IBunniToken bunniToken = hub.bunniTokenOfPool(id);
        if (address(bunniToken) == address(0) || msgSender != bunniToken.owner()) revert BunniHook__Unauthorized();
    }
}
