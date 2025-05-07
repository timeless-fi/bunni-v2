// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import "@uniswap/v4-core/src/types/PoolId.sol";
import "@uniswap/v4-core/src/types/Currency.sol";
import "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {AmAmm} from "biddog/AmAmm.sol";

import "flood-contracts/src/interfaces/IZone.sol";
import "flood-contracts/src/interfaces/IFloodPlain.sol";

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
import {IBunniHub} from "./interfaces/IBunniHub.sol";
import {BunniSwapMath} from "./lib/BunniSwapMath.sol";
import {BunniHookLogic} from "./lib/BunniHookLogic.sol";
import {ReentrancyGuard} from "./base/ReentrancyGuard.sol";

/// @title BunniHook
/// @author zefram.eth
/// @notice Uniswap v4 hook responsible for handling swaps on Bunni. Implements auto-rebalancing
/// executed via FloodPlain. Uses am-AMM to recapture LVR & MEV.
contract BunniHook is BaseHook, Ownable, IBunniHook, ReentrancyGuard, AmAmm {
    /// -----------------------------------------------------------------------
    /// Library usage
    /// -----------------------------------------------------------------------

    using SafeTransferLib for *;
    using FixedPointMathLib for *;
    using IdleBalanceLibrary for *;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using Oracle for Oracle.Observation[MAX_CARDINALITY];

    /// -----------------------------------------------------------------------
    /// Immutable args
    /// -----------------------------------------------------------------------

    uint48 internal immutable _K;
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

    /// @notice Used for computing the referral reward amount. Reward is `hookFee * referralRewardModifier / 1e6`.
    uint32 internal referralRewardModifier;

    /// @notice The FloodZone contract used in rebalance orders.
    IZone internal floodZone;

    /// @dev canWithdraw() returns false when a rebalance order is active. If rebalance orders don't get filled, withdrawals
    /// will continue to be blocked until the rebalance order is fulfilled since there is order resubmission. This allows
    /// the hook owner to manually unblock withdrawals for a pool.
    mapping(PoolId => bool) internal withdrawalUnblocked;

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
        address hookFeeRecipient_,
        uint32 hookFeeModifier_,
        uint32 referralRewardModifier_,
        uint48 k_
    ) BaseHook(poolManager_) {
        if (hookFeeModifier_ > MODIFIER_BASE || referralRewardModifier_ > MODIFIER_BASE) {
            revert BunniHook__InvalidModifier();
        }

        hub = hub_;
        floodPlain = floodPlain_;
        permit2 = address(floodPlain_.PERMIT2());
        weth = weth_;
        _K = k_;
        require(
            address(hub_) != address(0) && address(floodPlain_) != address(0) && address(permit2) != address(0)
                && address(weth_) != address(0) && owner_ != address(0) && k_ != 0
        );

        hookFeeRecipient = hookFeeRecipient_;
        hookFeeModifier = hookFeeModifier_;
        referralRewardModifier = referralRewardModifier_;
        floodZone = floodZone_;

        _initializeOwner(owner_);
        poolManager_.setOperator(address(hub_), true);

        emit SetModifiers(hookFeeModifier_, referralRewardModifier_);
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
    function claimProtocolFees(Currency[] calldata currencyList) external override nonReentrant {
        poolManager.unlock(abi.encode(HookUnlockCallbackType.CLAIM_FEES, abi.encode(currencyList)));
    }

    receive() external payable {}

    /// -----------------------------------------------------------------------
    /// Uniswap lock callback
    /// -----------------------------------------------------------------------

    enum HookUnlockCallbackType {
        REBALANCE_PREHOOK,
        REBALANCE_POSTHOOK,
        CLAIM_FEES
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override poolManagerOnly returns (bytes memory) {
        // decode input
        (HookUnlockCallbackType t, bytes memory callbackData) = abi.decode(data, (HookUnlockCallbackType, bytes));

        if (t == HookUnlockCallbackType.REBALANCE_PREHOOK) {
            _rebalancePrehookCallback(callbackData);
        } else if (t == HookUnlockCallbackType.REBALANCE_POSTHOOK) {
            _rebalancePosthookCallback(callbackData);
        } else if (t == HookUnlockCallbackType.CLAIM_FEES) {
            _claimFees(callbackData);
        }
        return bytes("");
    }

    /// @dev Calls hub.hookHandleSwap to pull the rebalance swap input tokens from BunniHub.
    /// Then burns PoolManager claim tokens and takes the underlying tokens from PoolManager.
    /// Used while executing rebalance orders.
    function _rebalancePrehookCallback(bytes memory callbackData) internal {
        // decode data
        (Currency currency, uint256 amount, PoolKey memory key, bool zeroForOne) =
            abi.decode(callbackData, (Currency, uint256, PoolKey, bool));

        // pull claim tokens from BunniHub
        hub.hookHandleSwap({key: key, zeroForOne: zeroForOne, inputAmount: 0, outputAmount: amount});

        // lock BunniHub to prevent reentrancy
        hub.lockForRebalance(key);

        // burn and take
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, address(this), amount);
    }

    /// @dev Settles tokens sent to PoolManager and mints the corresponding claim tokens.
    /// Then calls hub.hookGive to update pool balances with rebalance swap output.
    /// Used while executing rebalance orders.
    function _rebalancePosthookCallback(bytes memory callbackData) internal {
        // decode data
        (Currency currency, uint256 amount, PoolKey memory key, bool zeroForOne) =
            abi.decode(callbackData, (Currency, uint256, PoolKey, bool));

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

    /// @dev Claims protocol fees earned and sends it to the recipient.
    function _claimFees(bytes memory callbackData) internal {
        // decode data
        Currency[] memory currencyList = abi.decode(callbackData, (Currency[]));
        address recipient = hookFeeRecipient;

        // claim protocol fees
        for (uint256 i; i < currencyList.length; i++) {
            Currency currency = currencyList[i];
            // can claim balance - am-AMM accrued fees
            uint256 balance = poolManager.balanceOf(address(this), currency.toId()) - _totalFees[currency];
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
            }
        }

        emit ClaimProtocolFees(currencyList, recipient);
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

    function setHookFeeRecipient(address newHookFeeRecipient) external onlyOwner {
        hookFeeRecipient = newHookFeeRecipient;
        emit SetHookFeeRecipient(newHookFeeRecipient);
    }

    /// @inheritdoc IBunniHook
    function setModifiers(uint32 newHookFeeModifier, uint32 newReferralRewardModifier) external onlyOwner {
        if (newHookFeeModifier > MODIFIER_BASE || newReferralRewardModifier > MODIFIER_BASE) {
            revert BunniHook__InvalidModifier();
        }

        hookFeeModifier = newHookFeeModifier;
        referralRewardModifier = newReferralRewardModifier;

        emit SetModifiers(newHookFeeModifier, newReferralRewardModifier);
    }

    /// @inheritdoc IBunniHook
    function setWithdrawalUnblocked(PoolId id, bool unblocked) external onlyOwner {
        withdrawalUnblocked[id] = unblocked;
        emit SetWithdrawalUnblocked(id, unblocked);
    }

    /// -----------------------------------------------------------------------
    /// View functions
    /// -----------------------------------------------------------------------

    /// @inheritdoc IBunniHook
    function getObservation(PoolKey calldata key, uint256 index)
        external
        view
        override
        returns (Oracle.Observation memory observation)
    {
        observation = s.observations[key.toId()][index];
    }

    /// @inheritdoc IBunniHook
    function getState(PoolKey calldata key) external view override returns (ObservationState memory state) {
        state = s.states[key.toId()];
    }

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
    function vaultSharePricesAtLastSwap(PoolId id)
        external
        view
        returns (bool initialized, uint120 sharePrice0, uint120 sharePrice1)
    {
        VaultSharePrices memory prices = s.vaultSharePricesAtLastSwap[id];
        return (prices.initialized, prices.sharePrice0, prices.sharePrice1);
    }

    /// @inheritdoc IBunniHook
    function canWithdraw(PoolId id) external view returns (bool) {
        return block.timestamp > s.rebalanceOrderDeadline[id] || withdrawalUnblocked[id];
    }

    /// @inheritdoc IBunniHook
    function getHookFeeRecipient() external view returns (address) {
        return hookFeeRecipient;
    }

    /// @inheritdoc IBunniHook
    function getModifiers() external view returns (uint32 hookFeeModifier_, uint32 referralRewardModifier_) {
        return (hookFeeModifier, referralRewardModifier);
    }

    /// @inheritdoc IBunniHook
    function getClaimableHookFees(Currency[] calldata currencyList)
        external
        view
        returns (uint256[] memory feeAmounts)
    {
        feeAmounts = new uint256[](currencyList.length);
        for (uint256 i; i < currencyList.length; i++) {
            // can claim balance - am-AMM accrued fees
            Currency currency = currencyList[i];
            feeAmounts[i] = poolManager.balanceOf(address(this), currency.toId()) - _totalFees[currency];
        }
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
                referralRewardModifier: referralRewardModifier,
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
    function rebalanceOrderPreHook(RebalanceOrderHookArgs calldata hookArgs) external override nonReentrant {
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

        RebalanceOrderPreHookArgs calldata args = hookArgs.preHookArgs;

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
        poolManager.unlock(
            abi.encode(
                HookUnlockCallbackType.REBALANCE_PREHOOK,
                abi.encode(args.currency, args.amount, hookArgs.key, hookArgs.key.currency1 == args.currency)
            )
        );

        // ensure we have at least args.amount tokens so that there is enough input for the order
        if (args.currency.balanceOfSelf() < args.amount) {
            revert BunniHook__PrehookPostConditionFailed();
        }

        // wrap native ETH input to WETH
        // we're implicitly trusting the WETH contract won't charge a fee which is OK in practice
        if (args.currency.isAddressZero()) {
            weth.deposit{value: args.amount}();
        }
    }

    /// @inheritdoc IBunniHook
    function rebalanceOrderPostHook(RebalanceOrderHookArgs calldata hookArgs) external override nonReentrant {
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
        poolManager.unlock(
            abi.encode(
                HookUnlockCallbackType.REBALANCE_POSTHOOK,
                abi.encode(args.currency, orderOutputAmount, hookArgs.key, hookArgs.key.currency0 == args.currency)
            )
        );

        // recompute idle balance
        BunniHookLogic.recomputeIdleBalance(s, hub, hookArgs.key);
    }

    /// -----------------------------------------------------------------------
    /// AmAmm support
    /// -----------------------------------------------------------------------

    function K(PoolId) internal view virtual override returns (uint48) {
        return _K;
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

    /// @dev precedence is poolOverride > globalOverride > poolEnabled
    function _amAmmEnabled(PoolId id) internal view virtual override returns (bool) {
        bytes memory hookParams = hub.hookParams(id);
        bytes32 firstWord;
        /// @solidity memory-safe-assembly
        assembly {
            firstWord := mload(add(hookParams, 32))
        }
        bool poolEnabled = uint8(bytes1(firstWord << 248)) != 0;
        return poolEnabled;
    }

    function _payloadIsValid(PoolId id, bytes6 payload) internal view virtual override returns (bool) {
        // use feeMax from hookParams
        bytes memory hookParams = hub.hookParams(id);
        bytes32 firstWord;
        /// @solidity memory-safe-assembly
        assembly {
            firstWord := mload(add(hookParams, 32))
        }
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
}
