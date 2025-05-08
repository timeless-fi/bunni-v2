// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.19;

import "@uniswap/v4-core/src/types/PoolId.sol";
import "@uniswap/v4-core/src/types/Currency.sol";
import "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

import {WETH} from "solady/tokens/WETH.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import "./Math.sol";
import "./FeeMath.sol";
import "./VaultMath.sol";
import "./AmAmmPayload.sol";
import "../base/Errors.sol";
import "../types/LDFType.sol";
import "../base/Constants.sol";
import "../types/PoolState.sol";
import "../types/IdleBalance.sol";
import "../base/SharedStructs.sol";
import {Oracle} from "./Oracle.sol";
import "../interfaces/IBunniHook.sol";
import {queryLDF} from "./QueryLDF.sol";
import {BunniHook} from "../BunniHook.sol";
import {HookletLib} from "./HookletLib.sol";
import {BunniSwapMath} from "./BunniSwapMath.sol";
import {RebalanceLogic} from "./RebalanceLogic.sol";
import {IHooklet} from "../interfaces/IHooklet.sol";
import {IBunniHub} from "../interfaces/IBunniHub.sol";
import {LiquidityAmounts} from "./LiquidityAmounts.sol";

/// @title BunniHookLogic
/// @notice Split from BunniHook to reduce contract size below the Spurious Dragon limit
library BunniHookLogic {
    using TickMath for *;
    using SafeCastLib for *;
    using SafeTransferLib for *;
    using FixedPointMathLib for *;
    using HookletLib for IHooklet;
    using IdleBalanceLibrary for *;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using Oracle for Oracle.Observation[MAX_CARDINALITY];

    /// -----------------------------------------------------------------------
    /// Structs
    /// -----------------------------------------------------------------------

    struct Env {
        uint32 hookFeeModifier;
        uint32 referralRewardModifier;
        IBunniHub hub;
        IPoolManager poolManager;
        IFloodPlain floodPlain;
        IZone floodZone;
        WETH weth;
        address permit2;
    }

    struct RebalanceInput {
        PoolId id;
        PoolKey key;
        int24 updatedTick;
        uint160 updatedSqrtPriceX96;
        int24 arithmeticMeanTick;
        bytes32 newLdfState;
        DecodedHookParams hookParams;
        Oracle.Observation updatedIntermediate;
        uint32 updatedIndex;
        uint32 updatedCardinality;
    }

    /// -----------------------------------------------------------------------
    /// External functions
    /// -----------------------------------------------------------------------

    function afterInitialize(
        HookStorage storage s,
        address caller,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick,
        IBunniHub hub
    ) external {
        if (caller != address(hub)) revert BunniHook__Unauthorized(); // prevents non-BunniHub contracts from initializing a pool using this hook
        PoolId id = key.toId();

        // initialize slot0
        s.slot0s[id] = Slot0({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            lastSwapTimestamp: uint32(block.timestamp),
            lastSurgeTimestamp: 0
        });

        // read hook data from hub
        bytes memory hookData = hub.poolInitData();

        // initialize first observation to be dated in the past
        // so that we can immediately start querying the oracle
        (uint24 twapSecondsAgo, bytes memory hookParams) = abi.decode(hookData, (uint24, bytes));
        DecodedHookParams memory hookParamsDecoded = _decodeParams(hookParams);
        uint32 maxTwapSecondsAgo = uint32(
            FixedPointMathLib.max(
                FixedPointMathLib.max(twapSecondsAgo, hookParamsDecoded.feeTwapSecondsAgo),
                hookParamsDecoded.rebalanceTwapSecondsAgo
            )
        );
        (s.states[id].intermediateObservation, s.states[id].cardinality, s.states[id].cardinalityNext) =
            s.observations[id].initialize(uint32(block.timestamp - maxTwapSecondsAgo), tick);

        // increase cardinality target based on maxTwapSecondsAgo
        uint32 cardinalityNext =
            (maxTwapSecondsAgo + (hookParamsDecoded.oracleMinInterval >> 1)) / hookParamsDecoded.oracleMinInterval + 1; // round up + 1
        if (cardinalityNext > 1) {
            uint32 cardinalityNextNew = s.observations[id].grow(1, cardinalityNext);
            s.states[id].cardinalityNext = cardinalityNextNew;
        }
    }

    function beforeSwap(
        HookStorage storage s,
        Env calldata env,
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    )
        external
        returns (
            bool useAmAmmFee,
            address amAmmManager,
            Currency amAmmFeeCurrency,
            uint256 amAmmFeeAmount,
            BeforeSwapDelta beforeSwapDelta
        )
    {
        // skip 0 amount swaps
        if (params.amountSpecified == 0) {
            return (false, address(0), Currency.wrap(address(0)), 0, BeforeSwapDeltaLibrary.ZERO_DELTA);
        }

        // get pool state
        PoolId id = key.toId();
        Slot0 memory slot0 = s.slot0s[id];
        PoolState memory bunniState = env.hub.poolState(id);

        // hooklet call
        bool feeOverridden;
        uint24 feeOverride;
        {
            bool priceOverridden;
            uint160 sqrtPriceX96Override;
            (feeOverridden, feeOverride, priceOverridden, sqrtPriceX96Override) =
                bunniState.hooklet.hookletBeforeSwap(sender, key, params);

            // override price if needed
            if (priceOverridden) {
                slot0.sqrtPriceX96 = sqrtPriceX96Override;
                slot0.tick = sqrtPriceX96Override.getTickAtSqrtPrice();
            }
        }

        // ensure swap makes sense
        if (
            slot0.sqrtPriceX96 == 0
                || (
                    params.zeroForOne
                        && (
                            params.sqrtPriceLimitX96 >= slot0.sqrtPriceX96
                                || params.sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE
                        )
                )
                || (
                    !params.zeroForOne
                        && (
                            params.sqrtPriceLimitX96 <= slot0.sqrtPriceX96
                                || params.sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE
                        )
                ) || params.amountSpecified > type(int128).max || params.amountSpecified < type(int128).min
        ) {
            revert BunniHook__InvalidSwap();
        }

        // compute total token balances
        (uint256 reserveBalance0, uint256 reserveBalance1) = (
            getReservesInUnderlying(bunniState.reserve0, bunniState.vault0),
            getReservesInUnderlying(bunniState.reserve1, bunniState.vault1)
        );
        (uint256 balance0, uint256 balance1) =
            (bunniState.rawBalance0 + reserveBalance0, bunniState.rawBalance1 + reserveBalance1);

        // decode hook params
        DecodedHookParams memory hookParams = _decodeParams(bunniState.hookParams);

        // update TWAP oracle
        // do it before we fetch the arithmeticMeanTick
        // which doesn't change the result but gives us updated index and cardinality
        (Oracle.Observation memory updatedIntermediate, uint32 updatedIndex, uint32 updatedCardinality) =
            _updateOracle(s, id, slot0.tick, hookParams.oracleMinInterval);

        // get TWAP values
        int24 arithmeticMeanTick;
        int24 feeMeanTick;
        bool useLDFTwap = bunniState.twapSecondsAgo != 0;
        bool useFeeTwap = !feeOverridden && hookParams.feeTwapSecondsAgo != 0;
        if (useLDFTwap && useFeeTwap) {
            (int56 tickCumulatives0, int56 tickCumulatives1, int56 tickCumulatives2) = s.observations[id].observeTriple(
                updatedIntermediate,
                uint32(block.timestamp),
                0,
                bunniState.twapSecondsAgo,
                hookParams.feeTwapSecondsAgo,
                slot0.tick,
                updatedIndex,
                updatedCardinality
            );
            arithmeticMeanTick = int24((tickCumulatives0 - tickCumulatives1) / int56(uint56(bunniState.twapSecondsAgo)));
            feeMeanTick = int24((tickCumulatives0 - tickCumulatives2) / int56(uint56(hookParams.feeTwapSecondsAgo)));
        } else if (useLDFTwap) {
            arithmeticMeanTick = _getTwap(
                s, id, slot0.tick, bunniState.twapSecondsAgo, updatedIntermediate, updatedIndex, updatedCardinality
            );
        } else if (useFeeTwap) {
            feeMeanTick = _getTwap(
                s, id, slot0.tick, hookParams.feeTwapSecondsAgo, updatedIntermediate, updatedIndex, updatedCardinality
            );
        }

        // query the LDF to get total liquidity and token densities
        bytes32 ldfState = bunniState.ldfType == LDFType.DYNAMIC_AND_STATEFUL ? s.ldfStates[id] : bytes32(0);
        (
            uint256 totalLiquidity,
            ,
            ,
            uint256 liquidityDensityOfRoundedTickX96,
            uint256 currentActiveBalance0,
            uint256 currentActiveBalance1,
            bytes32 newLdfState,
            bool shouldSurge
        ) = queryLDF({
            key: key,
            sqrtPriceX96: slot0.sqrtPriceX96,
            tick: slot0.tick,
            arithmeticMeanTick: arithmeticMeanTick,
            ldf: bunniState.liquidityDensityFunction,
            ldfParams: bunniState.ldfParams,
            ldfState: ldfState,
            balance0: balance0,
            balance1: balance1,
            idleBalance: bunniState.idleBalance
        });

        // ensure the current active balance of the requested output token is not zero
        // or less than the requested output if it's an exact output swap
        bool exactIn = params.amountSpecified < 0;
        if (
            params.zeroForOne && currentActiveBalance1 == 0 || !params.zeroForOne && currentActiveBalance0 == 0
                || totalLiquidity == 0
                || (
                    !exactIn
                        && uint256(params.amountSpecified) > (params.zeroForOne ? currentActiveBalance1 : currentActiveBalance0)
                )
        ) {
            revert BunniHook__RequestedOutputExceedsBalance();
        }

        shouldSurge = shouldSurge && bunniState.ldfType != LDFType.STATIC; // only surge from LDF if LDF type is not static
        if (bunniState.ldfType == LDFType.DYNAMIC_AND_STATEFUL) s.ldfStates[id] = newLdfState;

        if (shouldSurge) {
            // the LDF has been updated, so we need to update the idle balance
            env.hub.hookSetIdleBalance(
                key,
                IdleBalanceLibrary.computeIdleBalance(currentActiveBalance0, currentActiveBalance1, balance0, balance1)
            );
        }

        // check surge based on vault share prices
        shouldSurge =
            shouldSurge || _shouldSurgeFromVaults(s, id, bunniState, hookParams, reserveBalance0, reserveBalance1);

        // compute swap result
        (uint160 updatedSqrtPriceX96, int24 updatedTick, uint256 inputAmount, uint256 outputAmount) = BunniSwapMath
            .computeSwap({
            input: BunniSwapMath.BunniComputeSwapInput({
                key: key,
                totalLiquidity: totalLiquidity,
                liquidityDensityOfRoundedTickX96: liquidityDensityOfRoundedTickX96,
                currentActiveBalance0: currentActiveBalance0,
                currentActiveBalance1: currentActiveBalance1,
                sqrtPriceX96: slot0.sqrtPriceX96,
                currentTick: slot0.tick,
                liquidityDensityFunction: bunniState.liquidityDensityFunction,
                arithmeticMeanTick: arithmeticMeanTick,
                ldfParams: bunniState.ldfParams,
                ldfState: ldfState,
                swapParams: params
            })
        });

        // revert if it's an exact output swap and outputAmount < params.amountSpecified
        if (!exactIn && outputAmount < uint256(params.amountSpecified)) {
            revert BunniHook__InsufficientOutput();
        }

        // ensure swap never moves price in the opposite direction
        // ensure the inputAmount and outputAmount are non-zero
        if (
            (params.zeroForOne && updatedSqrtPriceX96 > slot0.sqrtPriceX96)
                || (!params.zeroForOne && updatedSqrtPriceX96 < slot0.sqrtPriceX96)
                || (outputAmount == 0 || inputAmount == 0)
        ) {
            revert BunniHook__InvalidSwap();
        }

        // update slot0
        uint32 lastSurgeTimestamp = slot0.lastSurgeTimestamp;
        {
            uint32 blockTimestamp32 = uint32(block.timestamp);
            if (shouldSurge) {
                // use unchecked so that if uint32 overflows we wrap around
                // overflows are ok since we only look at differences
                unchecked {
                    uint32 timeSinceLastSwap = blockTimestamp32 - slot0.lastSwapTimestamp;
                    // if more than `surgeFeeAutostartThreshold` seconds has passed since the last swap,
                    // we pretend that the surge started at `slot0.lastSwapTimestamp + surgeFeeAutostartThreshold`
                    // so that the pool never gets stuck with a high fee
                    lastSurgeTimestamp = timeSinceLastSwap >= hookParams.surgeFeeAutostartThreshold
                        ? slot0.lastSwapTimestamp + hookParams.surgeFeeAutostartThreshold
                        : blockTimestamp32;
                }
            }
            s.slot0s[id] = Slot0({
                sqrtPriceX96: updatedSqrtPriceX96,
                tick: updatedTick,
                lastSwapTimestamp: blockTimestamp32,
                lastSurgeTimestamp: lastSurgeTimestamp
            });
        }

        // update am-AMM state
        uint24 amAmmSwapFee;
        if (hookParams.amAmmEnabled) {
            bytes6 payload;
            IAmAmm.Bid memory topBid = IAmAmm(address(this)).getTopBidWrite(id);
            (amAmmManager, payload) = (topBid.manager, topBid.payload);
            (uint24 swapFee0For1, uint24 swapFee1For0) = decodeAmAmmPayload(payload);
            amAmmSwapFee = params.zeroForOne ? swapFee0For1 : swapFee1For0;
        }

        // charge swap fee
        // precedence:
        // 1) am-AMM fee
        // 2) hooklet override fee
        // 3) dynamic fee
        (Currency inputToken, Currency outputToken) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        uint24 swapFee;
        uint256 swapFeeAmount;
        useAmAmmFee = hookParams.amAmmEnabled && amAmmManager != address(0);
        // swap fee used as the basis for computing hookFees when useAmAmmFee == true
        // this is to avoid a malicious am-AMM manager bypassing hookFees
        // by setting the swap fee to max and offering a proxy swap contract
        // that sets the Bunni swap fee to 0 during such swaps and charging swap fees
        // independently
        uint24 hookFeesBaseSwapFee = feeOverridden
            ? feeOverride
            : computeDynamicSwapFee(
                updatedSqrtPriceX96,
                feeMeanTick,
                lastSurgeTimestamp,
                hookParams.feeMin,
                hookParams.feeMax,
                hookParams.feeQuadraticMultiplier,
                hookParams.surgeFeeHalfLife
            );
        swapFee = useAmAmmFee
            ? uint24(FixedPointMathLib.max(amAmmSwapFee, computeSurgeFee(lastSurgeTimestamp, hookParams.surgeFeeHalfLife)))
            : hookFeesBaseSwapFee;
        uint256 hookFeesAmount;
        uint256 hookHandleSwapInputAmount;
        uint256 hookHandleSwapOutoutAmount;
        if (exactIn) {
            // compute the swap fee and the hook fee (i.e. protocol fee)
            // swap fee is taken by decreasing the output amount
            swapFeeAmount = outputAmount.mulDivUp(swapFee, SWAP_FEE_BASE);
            if (useAmAmmFee) {
                // instead of computing hook fees as a portion of the swap fee
                // and deducting it, we compute hook fees separately using hookFeesBaseSwapFee
                // and charge it as an extra fee on the swap
                hookFeesAmount = outputAmount.mulDivUp(hookFeesBaseSwapFee, SWAP_FEE_BASE).mulDivUp(
                    env.hookFeeModifier, MODIFIER_BASE
                );
            } else {
                hookFeesAmount = swapFeeAmount.mulDivUp(env.hookFeeModifier, MODIFIER_BASE);
                swapFeeAmount -= hookFeesAmount;
            }

            // set the am-AMM fee to be the swap fee amount
            // don't need to check if am-AMM is enabled since if it isn't
            // BunniHook.beforeSwap() simply ignores the returned values
            // this saves gas by avoiding an if statement
            (amAmmFeeCurrency, amAmmFeeAmount) = (outputToken, swapFeeAmount);

            // modify output amount with fees
            outputAmount -= swapFeeAmount + hookFeesAmount;

            // return beforeSwapDelta
            // take in max(amountSpecified, inputAmount) such that if amountSpecified is greater we just happily accept it
            int256 actualInputAmount = FixedPointMathLib.max(-params.amountSpecified, inputAmount.toInt256());
            inputAmount = uint256(actualInputAmount);
            beforeSwapDelta = toBeforeSwapDelta({
                deltaSpecified: actualInputAmount.toInt128(),
                deltaUnspecified: -outputAmount.toInt256().toInt128()
            });

            // if am-AMM is used, the swap fee needs to be taken from BunniHub, else it stays in BunniHub with the LPs
            (hookHandleSwapInputAmount, hookHandleSwapOutoutAmount) = (
                inputAmount, useAmAmmFee ? outputAmount + swapFeeAmount + hookFeesAmount : outputAmount + hookFeesAmount
            );
        } else {
            // compute the swap fee and the hook fee (i.e. protocol fee)
            // swap fee is taken by increasing the input amount
            // need to modify fee rate to maintain the same average price as exactIn case
            // in / (out * (1 - fee)) = in * (1 + fee') / out => fee' = fee / (1 - fee)
            swapFeeAmount = inputAmount.mulDivUp(swapFee, SWAP_FEE_BASE - swapFee);
            if (useAmAmmFee) {
                // instead of computing hook fees as a portion of the swap fee
                // and deducting it, we compute hook fees separately using hookFeesBaseSwapFee
                // and charge it as an extra fee on the swap
                hookFeesAmount = inputAmount.mulDivUp(hookFeesBaseSwapFee, SWAP_FEE_BASE - hookFeesBaseSwapFee).mulDivUp(
                    env.hookFeeModifier, MODIFIER_BASE
                );
            } else {
                hookFeesAmount = swapFeeAmount.mulDivUp(env.hookFeeModifier, MODIFIER_BASE);
                swapFeeAmount -= hookFeesAmount;
            }

            // set the am-AMM fee to be the swap fee amount
            // don't need to check if am-AMM is enabled since if it isn't
            // BunniHook.beforeSwap() simply ignores the returned values
            // this saves gas by avoiding an if statement
            (amAmmFeeCurrency, amAmmFeeAmount) = (inputToken, swapFeeAmount);

            // modify input amount with fees
            inputAmount += swapFeeAmount + hookFeesAmount;

            // return beforeSwapDelta
            // give out min(amountSpecified, outputAmount) such that we only give out as much as requested
            int256 actualOutputAmount = FixedPointMathLib.min(params.amountSpecified, outputAmount.toInt256());
            outputAmount = uint256(actualOutputAmount);
            beforeSwapDelta = toBeforeSwapDelta({
                deltaSpecified: -actualOutputAmount.toInt128(),
                deltaUnspecified: inputAmount.toInt256().toInt128()
            });

            // if am-AMM is not used, the swap fee needs to be sent to BunniHub to the LPs, else it stays in BunniHook with the am-AMM manager
            (hookHandleSwapInputAmount, hookHandleSwapOutoutAmount) = (
                useAmAmmFee ? inputAmount - swapFeeAmount - hookFeesAmount : inputAmount - hookFeesAmount, outputAmount
            );
        }

        // take input by minting claim tokens to hook
        env.poolManager.mint(address(this), inputToken.toId(), inputAmount);

        // call hub to handle swap
        // - pull input claim tokens from hook
        // - push output tokens to pool manager and mint claim tokens to hook
        // - update raw token balances
        env.hub.hookHandleSwap(key, params.zeroForOne, hookHandleSwapInputAmount, hookHandleSwapOutoutAmount);

        // burn output claim tokens
        env.poolManager.burn(address(this), outputToken.toId(), outputAmount);

        // distribute part of hookFees to referrers
        if (hookFeesAmount != 0) {
            uint256 referrerRewardAmount = hookFeesAmount.mulDiv(env.referralRewardModifier, MODIFIER_BASE);
            if (referrerRewardAmount != 0) {
                if (!env.poolManager.isOperator(address(this), address(bunniState.bunniToken))) {
                    env.poolManager.setOperator(address(bunniState.bunniToken), true);
                }
                bool isToken0 = exactIn != params.zeroForOne;
                bunniState.bunniToken.distributeReferralRewards(isToken0, referrerRewardAmount);
            }
        }

        // emit swap event
        emit IBunniHook.Swap(
            id,
            sender,
            exactIn,
            params.zeroForOne,
            inputAmount,
            outputAmount,
            updatedSqrtPriceX96,
            updatedTick,
            swapFee,
            totalLiquidity
        );

        // we should attempt to rebalance if:
        // 1) rebalanceThreshold != 0, i.e. rebalancing is enabled
        // 2.a) either shouldSurge == true, since tokens can only go out of balance due to shifting or vault returns, or:
        // 2.b) the deadline of the last rebalance order has passed and the order wasn't executed, in which case we should reattempt to rebalance
        uint256 rebalanceOrderDeadline = shouldSurge ? 0 : s.rebalanceOrderDeadline[id]; // gas: only do SLOAD if shouldSurge == false
        if (
            hookParams.rebalanceThreshold != 0
                && (shouldSurge || (block.timestamp > rebalanceOrderDeadline && rebalanceOrderDeadline != 0))
        ) {
            if (shouldSurge) {
                // surging makes any existing rebalance order meaningless
                // since the desired token ratio will be different
                // clear the existing rebalance order
                delete s.rebalanceOrderHash[id];
                delete s.rebalanceOrderPermit2Hash[id];
                delete s.rebalanceOrderDeadline[id];
            }

            RebalanceLogic.rebalance(
                s,
                env,
                RebalanceInput({
                    id: id,
                    key: key,
                    updatedTick: updatedTick,
                    updatedSqrtPriceX96: updatedSqrtPriceX96,
                    arithmeticMeanTick: arithmeticMeanTick,
                    newLdfState: newLdfState,
                    hookParams: hookParams,
                    updatedIntermediate: updatedIntermediate,
                    updatedIndex: updatedIndex,
                    updatedCardinality: updatedCardinality
                })
            );
        }

        // hooklet call
        if (bunniState.hooklet.hasPermission(HookletLib.AFTER_SWAP_FLAG)) {
            bunniState.hooklet.hookletAfterSwap(
                sender,
                key,
                params,
                IHooklet.SwapReturnData({
                    updatedSqrtPriceX96: updatedSqrtPriceX96,
                    updatedTick: updatedTick,
                    inputAmount: inputAmount,
                    outputAmount: outputAmount,
                    swapFee: swapFee,
                    totalLiquidity: totalLiquidity
                })
            );
        }
    }

    function recomputeIdleBalance(HookStorage storage s, IBunniHub hub, PoolKey calldata key) external {
        PoolId id = key.toId();
        PoolState memory bunniState = hub.poolState(id);
        Slot0 memory slot0 = s.slot0s[id];
        (uint256 balance0, uint256 balance1) = (
            bunniState.rawBalance0 + getReservesInUnderlying(bunniState.reserve0, bunniState.vault0),
            bunniState.rawBalance1 + getReservesInUnderlying(bunniState.reserve1, bunniState.vault1)
        );
        int24 arithmeticMeanTick = bunniState.twapSecondsAgo == 0
            ? int24(0)
            : _getTwap(
                s,
                id,
                slot0.tick,
                bunniState.twapSecondsAgo,
                s.states[id].intermediateObservation,
                s.states[id].index,
                s.states[id].cardinality
            );
        bytes32 ldfState = bunniState.ldfType == LDFType.DYNAMIC_AND_STATEFUL ? s.ldfStates[id] : bytes32(0);
        (,,,, uint256 currentActiveBalance0, uint256 currentActiveBalance1,,) = queryLDF({
            key: key,
            sqrtPriceX96: slot0.sqrtPriceX96,
            tick: slot0.tick,
            arithmeticMeanTick: arithmeticMeanTick,
            ldf: bunniState.liquidityDensityFunction,
            ldfParams: bunniState.ldfParams,
            ldfState: ldfState,
            balance0: balance0,
            balance1: balance1,
            idleBalance: IdleBalanceLibrary.ZERO // set to zero since we're recomputing the idle balance and shouldSurge isn't necessarily true
        });
        hub.hookSetIdleBalance(
            key, IdleBalanceLibrary.computeIdleBalance(currentActiveBalance0, currentActiveBalance1, balance0, balance1)
        );
    }

    function isValidParams(bytes calldata hookParams) external pure returns (bool) {
        DecodedHookParams memory p = _decodeParams(hookParams);
        unchecked {
            return (p.feeMin <= p.feeMax) && (p.feeMax < SWAP_FEE_BASE)
                && (p.feeQuadraticMultiplier == 0 || p.feeMin == p.feeMax || p.feeTwapSecondsAgo != 0)
                && (uint256(p.surgeFeeHalfLife) * uint256(p.vaultSurgeThreshold0) * uint256(p.vaultSurgeThreshold1) != 0)
                && (p.surgeFeeHalfLife < MAX_SURGE_HALFLIFE && p.surgeFeeAutostartThreshold < MAX_SURGE_AUTOSTART_TIME)
                && (
                    (
                        p.rebalanceThreshold == 0 && p.rebalanceMaxSlippage == 0 && p.rebalanceTwapSecondsAgo == 0
                            && p.rebalanceOrderTTL == 0
                    )
                        || (
                            p.rebalanceThreshold != 0 && p.rebalanceMaxSlippage != 0
                                && p.rebalanceMaxSlippage < REBALANCE_MAX_SLIPPAGE_BASE && p.rebalanceTwapSecondsAgo != 0
                                && p.rebalanceTwapSecondsAgo < MAX_REBALANCE_TWAP_SECONDS_AGO && p.rebalanceOrderTTL != 0
                                && p.rebalanceOrderTTL < MAX_REBALANCE_ORDER_TTL
                        )
                ) && (p.oracleMinInterval != 0)
                && (!p.amAmmEnabled || (p.maxAmAmmFee != 0 && p.maxAmAmmFee <= MAX_AMAMM_FEE && p.minRentMultiplier != 0));
        }
    }

    function decodeHookParams(bytes calldata hookParams) external pure returns (DecodedHookParams memory p) {
        return _decodeParams(hookParams);
    }

    function observe(HookStorage storage s, PoolKey calldata key, uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives)
    {
        PoolId id = key.toId();
        IBunniHook.ObservationState memory state = s.states[id];
        Slot0 memory slot0 = s.slot0s[id];

        return s.observations[id].observe(
            state.intermediateObservation,
            uint32(block.timestamp),
            secondsAgos,
            slot0.tick,
            state.index,
            state.cardinality
        );
    }

    /// -----------------------------------------------------------------------
    /// Internal utility functions
    /// -----------------------------------------------------------------------

    /// @dev Checks if the pool should surge based on the vault share price changes since the last swap.
    /// Also updates vaultSharePricesAtLastSwap.
    function _shouldSurgeFromVaults(
        HookStorage storage s,
        PoolId id,
        PoolState memory bunniState,
        DecodedHookParams memory hookParams,
        uint256 reserveBalance0,
        uint256 reserveBalance1
    ) private returns (bool shouldSurge) {
        if (address(bunniState.vault0) != address(0) || address(bunniState.vault1) != address(0)) {
            // only surge if at least one vault is set because otherwise total liquidity won't automatically increase
            // so there's no risk of being sandwiched

            // load share prices at last swap
            VaultSharePrices memory prevSharePrices = s.vaultSharePricesAtLastSwap[id];

            // compute current share prices
            // need to rescale token/vault balances to use 18 decimals
            // sharePrice = (reserveBalance * (10**18) / (10**currencyDecimals)) * (10**18) / (reserve * (10**18) / (10**vaultDecimals))
            // = reserveBalance * (10**(18 + vaultDecimals - currencyDecimals)) / reserve
            // (18 + vaultDecimals - currencyDecimals) is always >= 0 since it's verified in BunniHubLogic::deployBunniToken()
            // unless vault is address(0) but then the reserve will always be 0 so rescaleFactor is irrelevant
            uint8 rescaleFactor0;
            uint8 rescaleFactor1;
            unchecked {
                rescaleFactor0 = 18 + bunniState.vault0Decimals - bunniState.currency0Decimals;
                rescaleFactor1 = 18 + bunniState.vault1Decimals - bunniState.currency1Decimals;
            }
            uint120 sharePrice0 = bunniState.reserve0 == 0
                ? 0
                : reserveBalance0.mulDivUp(10 ** rescaleFactor0, bunniState.reserve0).toUint120();
            uint120 sharePrice1 = bunniState.reserve1 == 0
                ? 0
                : reserveBalance1.mulDivUp(10 ** rescaleFactor1, bunniState.reserve1).toUint120();

            // compare with share prices at last swap to see if we need to apply the surge fee
            // surge fee is applied if the share price has increased by more than 1 / vaultSurgeThreshold
            shouldSurge = prevSharePrices.initialized
                && (
                    dist(sharePrice0, prevSharePrices.sharePrice0)
                        > prevSharePrices.sharePrice0 / hookParams.vaultSurgeThreshold0
                        || dist(sharePrice1, prevSharePrices.sharePrice1)
                            > prevSharePrices.sharePrice1 / hookParams.vaultSurgeThreshold1
                );

            // update share prices at last swap
            if (
                !prevSharePrices.initialized || sharePrice0 != prevSharePrices.sharePrice0
                    || sharePrice1 != prevSharePrices.sharePrice1
            ) {
                s.vaultSharePricesAtLastSwap[id] =
                    VaultSharePrices({initialized: true, sharePrice0: sharePrice0, sharePrice1: sharePrice1});
            }
        }
    }

    function _getTwap(
        HookStorage storage s,
        PoolId id,
        int24 currentTick,
        uint32 twapSecondsAgo,
        Oracle.Observation memory updatedIntermediate,
        uint32 updatedIndex,
        uint32 updatedCardinality
    ) internal view returns (int24 arithmeticMeanTick) {
        (int56 tickCumulative0, int56 tickCumulative1) = s.observations[id].observeDouble(
            updatedIntermediate,
            uint32(block.timestamp),
            twapSecondsAgo,
            0,
            currentTick,
            updatedIndex,
            updatedCardinality
        );
        int56 tickCumulativesDelta = tickCumulative1 - tickCumulative0;
        arithmeticMeanTick = int24(tickCumulativesDelta / int56(uint56(twapSecondsAgo)));
    }

    function _updateOracle(HookStorage storage s, PoolId id, int24 tick, uint32 oracleMinInterval)
        internal
        returns (Oracle.Observation memory updatedIntermediate, uint32 updatedIndex, uint32 updatedCardinality)
    {
        IBunniHook.ObservationState memory state = s.states[id];
        (updatedIntermediate, updatedIndex, updatedCardinality) = s.observations[id].write(
            state.intermediateObservation,
            state.index,
            uint32(block.timestamp),
            tick,
            state.cardinality,
            state.cardinalityNext,
            oracleMinInterval
        );
        (s.states[id].intermediateObservation, s.states[id].index, s.states[id].cardinality) =
            (updatedIntermediate, updatedIndex, updatedCardinality);
    }

    /// @dev Decodes hookParams into params used by this hook
    /// @param hookParams The hook params raw bytes
    /// @return p The decoded params struct
    function _decodeParams(bytes memory hookParams) internal pure returns (DecodedHookParams memory p) {
        // | feeMin - 3 bytes | feeMax - 3 bytes | feeQuadraticMultiplier - 3 bytes | feeTwapSecondsAgo - 3 bytes | maxAmAmmFee - 3 bytes | surgeFeeHalfLife - 2 bytes | surgeFeeAutostartThreshold - 2 bytes | vaultSurgeThreshold0 - 2 bytes | vaultSurgeThreshold1 - 2 bytes | rebalanceThreshold - 2 bytes | rebalanceMaxSlippage - 2 bytes | rebalanceTwapSecondsAgo - 2 bytes | rebalanceOrderTTL - 2 bytes | amAmmEnabled - 1 byte |
        bytes32 firstWord;
        // | oracleMinInterval - 4 bytes | minRentMultiplier - 6 bytes |
        bytes32 secondWord;
        /// @solidity memory-safe-assembly
        assembly {
            firstWord := mload(add(hookParams, 32))
            secondWord := mload(add(hookParams, 64))
        }
        p.feeMin = uint24(bytes3(firstWord));
        p.feeMax = uint24(bytes3(firstWord << 24));
        p.feeQuadraticMultiplier = uint24(bytes3(firstWord << 48));
        p.feeTwapSecondsAgo = uint24(bytes3(firstWord << 72));
        p.maxAmAmmFee = uint24(bytes3(firstWord << 96));
        p.surgeFeeHalfLife = uint16(bytes2(firstWord << 120));
        p.surgeFeeAutostartThreshold = uint16(bytes2(firstWord << 136));
        p.vaultSurgeThreshold0 = uint16(bytes2(firstWord << 152));
        p.vaultSurgeThreshold1 = uint16(bytes2(firstWord << 168));
        p.rebalanceThreshold = uint16(bytes2(firstWord << 184));
        p.rebalanceMaxSlippage = uint16(bytes2(firstWord << 200));
        p.rebalanceTwapSecondsAgo = uint16(bytes2(firstWord << 216));
        p.rebalanceOrderTTL = uint16(bytes2(firstWord << 232));
        p.amAmmEnabled = uint8(bytes1(firstWord << 248)) != 0;
        p.oracleMinInterval = uint32(bytes4(secondWord));
        p.minRentMultiplier = uint48(bytes6(secondWord << 32));
    }
}
