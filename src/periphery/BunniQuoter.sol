// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager, PoolKey} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {IAmAmm} from "biddog/interfaces/IAmAmm.sol";

import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {IHooklet} from "../interfaces/IHooklet.sol";
import {IBunniHub} from "../interfaces/IBunniHub.sol";
import {IBunniHook} from "../interfaces/IBunniHook.sol";
import {IBunniQuoter} from "../interfaces/IBunniQuoter.sol";

import "../lib/Math.sol";
import "../lib/FeeMath.sol";
import "../lib/QueryTWAP.sol";
import "../lib/VaultMath.sol";
import "../types/LDFType.sol";
import "../base/Constants.sol";
import "../types/PoolState.sol";
import "../lib/AmAmmPayload.sol";
import "../lib/BunniSwapMath.sol";
import "../base/SharedStructs.sol";
import {HookletLib} from "../lib/HookletLib.sol";
import {FullMathX96} from "../lib/FullMathX96.sol";
import {BunniHookLogic} from "../lib/BunniHookLogic.sol";
import {LiquidityAmounts} from "../lib/LiquidityAmounts.sol";

contract BunniQuoter is IBunniQuoter {
    using TickMath for *;
    using SafeCastLib for *;
    using FullMathX96 for *;
    using FixedPointMathLib for *;
    using HookletLib for IHooklet;
    using PoolIdLibrary for PoolKey;

    IBunniHub internal immutable hub;

    constructor(IBunniHub hub_) {
        hub = hub_;
    }

    /// -----------------------------------------------------------------------
    /// External functions
    /// -----------------------------------------------------------------------

    /// @inheritdoc IBunniQuoter
    function quoteSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params)
        external
        view
        override
        returns (
            bool success,
            uint160 updatedSqrtPriceX96,
            int24 updatedTick,
            uint256 inputAmount,
            uint256 outputAmount,
            uint24 swapFee,
            uint256 totalLiquidity
        )
    {
        // get pool state
        PoolId id = key.toId();
        IBunniHook hook = IBunniHook(address(key.hooks));
        (uint160 sqrtPriceX96, int24 currentTick, uint32 lastSwapTimestamp, uint32 lastSurgeTimestamp) = hook.slot0s(id);
        PoolState memory bunniState = hub.poolState(id);

        // hooklet call
        (bool success_, bool feeOverridden, uint24 feeOverride, bool priceOverridden, uint160 sqrtPriceX96Override) =
            bunniState.hooklet.hookletBeforeSwapView(sender, key, params);
        if (!success_) return (false, 0, 0, 0, 0, 0, 0);

        // override price if needed
        if (priceOverridden) {
            sqrtPriceX96 = sqrtPriceX96Override;
            currentTick = sqrtPriceX96Override.getTickAtSqrtPrice();
        }

        // ensure swap makes sense
        if (
            sqrtPriceX96 == 0
                || (
                    params.zeroForOne
                        && (params.sqrtPriceLimitX96 >= sqrtPriceX96 || params.sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE)
                )
                || (
                    !params.zeroForOne
                        && (params.sqrtPriceLimitX96 <= sqrtPriceX96 || params.sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE)
                ) || params.amountSpecified > type(int128).max || params.amountSpecified < type(int128).min
        ) {
            return (false, 0, 0, 0, 0, 0, 0);
        }

        // compute total token balances
        (uint256 reserveBalance0, uint256 reserveBalance1) = (
            getReservesInUnderlying(bunniState.reserve0, bunniState.vault0),
            getReservesInUnderlying(bunniState.reserve1, bunniState.vault1)
        );
        (uint256 balance0, uint256 balance1) =
            (bunniState.rawBalance0 + reserveBalance0, bunniState.rawBalance1 + reserveBalance1);

        // if it's an exact output swap, exit if the requested output is greater than the balance
        bool exactIn = params.amountSpecified < 0;
        if (!exactIn && uint256(params.amountSpecified) > (params.zeroForOne ? balance1 : balance0)) {
            return (false, 0, 0, 0, 0, 0, 0);
        }

        // decode hook params
        DecodedHookParams memory hookParams = BunniHookLogic.decodeHookParams(bunniState.hookParams);

        // get TWAP values
        int24 arithmeticMeanTick = bunniState.twapSecondsAgo != 0 ? queryTwap(key, bunniState.twapSecondsAgo) : int24(0);
        int24 feeMeanTick = (!feeOverridden && hookParams.feeTwapSecondsAgo != 0)
            ? queryTwap(key, hookParams.feeTwapSecondsAgo)
            : int24(0);

        // query the LDF to get total liquidity and token densities
        bytes32 ldfState = bunniState.ldfType == LDFType.DYNAMIC_AND_STATEFUL ? hook.ldfStates(id) : bytes32(0);
        (
            uint256 totalLiquidity_,
            ,
            ,
            uint256 liquidityDensityOfRoundedTickX96,
            uint256 currentActiveBalance0,
            uint256 currentActiveBalance1,
            ,
            bool shouldSurge
        ) = queryLDF({
            key: key,
            sqrtPriceX96: sqrtPriceX96,
            tick: currentTick,
            arithmeticMeanTick: arithmeticMeanTick,
            ldf: bunniState.liquidityDensityFunction,
            ldfParams: bunniState.ldfParams,
            ldfState: ldfState,
            balance0: balance0,
            balance1: balance1,
            idleBalance: bunniState.idleBalance
        });
        shouldSurge = shouldSurge && bunniState.ldfType != LDFType.STATIC;
        totalLiquidity = totalLiquidity_;

        // ensure the current active balance of the requested output token is not zero
        if (
            params.zeroForOne && currentActiveBalance1 == 0 || !params.zeroForOne && currentActiveBalance0 == 0
                || totalLiquidity == 0
                || (
                    !exactIn
                        && uint256(params.amountSpecified) > (params.zeroForOne ? currentActiveBalance1 : currentActiveBalance0)
                )
        ) {
            return (false, 0, 0, 0, 0, 0, 0);
        }

        // check surge based on vault share prices
        shouldSurge =
            shouldSurge || _shouldSurgeFromVaults(id, hook, bunniState, hookParams, reserveBalance0, reserveBalance1);

        // compute swap result
        (updatedSqrtPriceX96, updatedTick, inputAmount, outputAmount) = BunniSwapMath.computeSwap({
            input: BunniSwapMath.BunniComputeSwapInput({
                key: key,
                totalLiquidity: totalLiquidity,
                liquidityDensityOfRoundedTickX96: liquidityDensityOfRoundedTickX96,
                currentActiveBalance0: currentActiveBalance0,
                currentActiveBalance1: currentActiveBalance1,
                sqrtPriceX96: sqrtPriceX96,
                currentTick: currentTick,
                liquidityDensityFunction: bunniState.liquidityDensityFunction,
                arithmeticMeanTick: arithmeticMeanTick,
                ldfParams: bunniState.ldfParams,
                ldfState: ldfState,
                swapParams: params
            })
        });

        // exit if it's an exact output swap and outputAmount < params.amountSpecified
        // ensure swap never moves price in the opposite direction
        // ensure the inputAmount is non-zero when it's an exact output swap
        if (
            (!exactIn && outputAmount < uint256(params.amountSpecified))
                || (params.zeroForOne && updatedSqrtPriceX96 > sqrtPriceX96)
                || (!params.zeroForOne && updatedSqrtPriceX96 < sqrtPriceX96) || (outputAmount == 0 || inputAmount == 0)
        ) {
            return (false, 0, 0, 0, 0, 0, 0);
        }

        if (shouldSurge) {
            // use unchecked so that if uint32 overflows we wrap around
            // overflows are ok since we only look at differences
            unchecked {
                uint32 timeSinceLastSwap = uint32(block.timestamp) - lastSwapTimestamp;
                // if more than `surgeFeeAutostartThreshold` seconds has passed since the last swap,
                // we pretend that the surge started at `lastSwapTimestamp + surgeFeeAutostartThreshold`
                // so that the pool never gets stuck with a high fee
                lastSurgeTimestamp = timeSinceLastSwap >= hookParams.surgeFeeAutostartThreshold
                    ? lastSwapTimestamp + hookParams.surgeFeeAutostartThreshold
                    : uint32(block.timestamp);
            }
        }

        // get am-AMM state
        uint24 amAmmSwapFee;
        address amAmmManager;
        if (hookParams.amAmmEnabled) {
            bytes6 payload;
            IAmAmm.Bid memory topBid = hook.getTopBid(id);
            (amAmmManager, payload) = (topBid.manager, topBid.payload);
            uint24 swapFee0For1;
            uint24 swapFee1For0;
            (swapFee0For1, swapFee1For0) = decodeAmAmmPayload(payload);
            amAmmSwapFee = params.zeroForOne ? swapFee0For1 : swapFee1For0;
        }

        // charge swap fee
        // precedence:
        // 1) am-AMM fee
        // 2) hooklet override fee
        // 3) dynamic fee
        uint256 swapFeeAmount;
        bool useAmAmmFee = hookParams.amAmmEnabled && amAmmManager != address(0);
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
        if (exactIn) {
            // compute the swap fee and the hook fee (i.e. protocol fee)
            // swap fee is taken by decreasing the output amount
            swapFeeAmount = outputAmount.mulDivUp(swapFee, SWAP_FEE_BASE);
            if (useAmAmmFee) {
                // instead of computing hook fees as a portion of the swap fee
                // and deducting it, we compute hook fees separately using hookFeesBaseSwapFee
                // and charge it as an extra fee on the swap
                (uint32 hookFeeModifier,) = hook.getModifiers();
                uint256 hookFeesAmount =
                    outputAmount.mulDivUp(hookFeesBaseSwapFee, SWAP_FEE_BASE).mulDivUp(hookFeeModifier, MODIFIER_BASE);
                swapFeeAmount += hookFeesAmount; // add hook fees to swapFeeAmount since we're only using it for computing inputAmount
                swapFee += uint24(hookFeesBaseSwapFee.mulDivUp(hookFeeModifier, MODIFIER_BASE)); // modify effective swap fee for swapper
            }
            outputAmount -= swapFeeAmount;

            // take in max(amountSpecified, inputAmount) such that if amountSpecified is greater we just happily accept it
            int256 actualInputAmount = FixedPointMathLib.max(-params.amountSpecified, inputAmount.toInt256());
            inputAmount = uint256(actualInputAmount);
        } else {
            // increase input amount
            // need to modify fee rate to maintain the same average price as exactIn case
            // in / (out * (1 - fee)) = in * (1 + fee') / out => fee' = fee / (1 - fee)
            swapFeeAmount = inputAmount.mulDivUp(swapFee, SWAP_FEE_BASE - swapFee);
            if (useAmAmmFee) {
                // instead of computing hook fees as a portion of the swap fee
                // and deducting it, we compute hook fees separately using hookFeesBaseSwapFee
                // and charge it as an extra fee on the swap
                (uint32 hookFeeModifier,) = hook.getModifiers();
                uint256 hookFeesAmount = inputAmount.mulDivUp(hookFeesBaseSwapFee, SWAP_FEE_BASE - hookFeesBaseSwapFee)
                    .mulDivUp(hookFeeModifier, MODIFIER_BASE);
                swapFeeAmount += hookFeesAmount; // add hook fees to swapFeeAmount since we're only using it for computing inputAmount
                swapFee += uint24(hookFeesBaseSwapFee.mulDivUp(hookFeeModifier, MODIFIER_BASE)); // modify effective swap fee for swapper
            }
            inputAmount += swapFeeAmount;

            // give out min(amountSpecified, outputAmount) such that if amountSpecified is greater we only give outputAmount and let the tx revert
            int256 actualOutputAmount = FixedPointMathLib.min(params.amountSpecified, outputAmount.toInt256());
            outputAmount = uint256(actualOutputAmount);
        }

        // hooklet call
        success = bunniState.hooklet.hookletAfterSwapView(
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

    /// @inheritdoc IBunniQuoter
    function quoteDeposit(address sender, IBunniHub.DepositParams calldata params)
        external
        view
        override
        returns (bool success, uint256 shares, uint256 amount0, uint256 amount1)
    {
        PoolId poolId = params.poolKey.toId();
        PoolState memory state = hub.poolState(poolId);

        (uint160 sqrtPriceX96, int24 currentTick,,) = IBunniHook(address(params.poolKey.hooks)).slot0s(poolId);

        // hooklet call
        success = state.hooklet.hookletBeforeDepositView(sender, params);
        if (!success) return (false, 0, 0, 0);

        DepositLogicReturnData memory depositReturnData = _depositLogic(
            DepositLogicInputData({
                state: state,
                params: params,
                poolKey: params.poolKey,
                poolId: poolId,
                currentTick: currentTick,
                sqrtPriceX96: sqrtPriceX96
            })
        );
        if (!depositReturnData.success) {
            return (false, 0, 0, 0);
        }
        amount0 = depositReturnData.amount0;
        amount1 = depositReturnData.amount1;

        (uint256 rawAmount0, uint256 reserveAmount0) = address(state.vault0) != address(0)
            ? (amount0 - depositReturnData.reserveAmount0, depositReturnData.reserveAmount0)
            : (amount0, 0);
        (uint256 rawAmount1, uint256 reserveAmount1) = address(state.vault1) != address(0)
            ? (amount1 - depositReturnData.reserveAmount1, depositReturnData.reserveAmount1)
            : (amount1, 0);

        // compute shares
        uint256 existingShareSupply = state.bunniToken.totalSupply();
        (uint256 addedAmount0, uint256 addedAmount1) = (rawAmount0 + reserveAmount0, rawAmount1 + reserveAmount1);
        if (existingShareSupply == 0) {
            // ensure that the added amounts are not too small to mess with the shares math
            if (addedAmount0 < MIN_DEPOSIT_BALANCE_INCREASE && addedAmount1 < MIN_DEPOSIT_BALANCE_INCREASE) {
                return (false, 0, 0, 0);
            }
            // no existing shares, just give WAD - MIN_INITIAL_SHARES
            shares = WAD - MIN_INITIAL_SHARES;
        } else {
            // given that the position may become single-sided, we need to handle the case where one of the existingAmount values is zero
            shares = FixedPointMathLib.min(
                depositReturnData.balance0 == 0
                    ? type(uint256).max
                    : existingShareSupply.mulDiv(addedAmount0, depositReturnData.balance0),
                depositReturnData.balance1 == 0
                    ? type(uint256).max
                    : existingShareSupply.mulDiv(addedAmount1, depositReturnData.balance1)
            );
        }

        // hooklet call
        success = state.hooklet.hookletAfterDepositView(
            sender, params, IHooklet.DepositReturnData({shares: shares, amount0: amount0, amount1: amount1})
        );
    }

    /// @inheritdoc IBunniQuoter
    function quoteWithdraw(address sender, IBunniHub.WithdrawParams calldata params)
        external
        view
        override
        returns (bool success, uint256 amount0, uint256 amount1)
    {
        PoolId poolId = params.poolKey.toId();
        PoolState memory state = hub.poolState(poolId);
        IBunniHook hook = IBunniHook(address(params.poolKey.hooks));

        if (!hook.canWithdraw(poolId)) {
            return (false, 0, 0);
        }

        // hooklet call
        success = state.hooklet.hookletBeforeWithdrawView(sender, params);
        if (!success) return (false, 0, 0);

        uint256 currentTotalSupply = state.bunniToken.totalSupply();

        // compute token amount to withdraw and the component amounts
        uint256 reserveAmount0 =
            getReservesInUnderlying(state.reserve0.mulDiv(params.shares, currentTotalSupply), state.vault0);
        uint256 reserveAmount1 =
            getReservesInUnderlying(state.reserve1.mulDiv(params.shares, currentTotalSupply), state.vault1);
        uint256 rawAmount0 = state.rawBalance0.mulDiv(params.shares, currentTotalSupply);
        uint256 rawAmount1 = state.rawBalance1.mulDiv(params.shares, currentTotalSupply);
        amount0 = reserveAmount0 + rawAmount0;
        amount1 = reserveAmount1 + rawAmount1;

        // hooklet call
        success = state.hooklet.hookletAfterWithdrawView(
            sender, params, IHooklet.WithdrawReturnData({amount0: amount0, amount1: amount1})
        );
    }

    /// @inheritdoc IBunniQuoter
    function getTotalLiquidity(PoolKey calldata key) external view returns (uint256 totalLiquidity) {
        PoolId id = key.toId();
        IBunniHook hook = IBunniHook(address(key.hooks));

        // load fresh state
        PoolState memory bunniState = hub.poolState(id);
        (uint160 updatedSqrtPriceX96, int24 updatedTick,,) = hook.slot0s(id);

        int24 arithmeticMeanTick;
        if (bunniState.twapSecondsAgo != 0) {
            arithmeticMeanTick = _getTwap(key, bunniState.twapSecondsAgo);
        }
        bytes32 newLdfState = hook.ldfStates(id);

        // get fresh token balances
        (uint256 balance0, uint256 balance1) = (
            bunniState.rawBalance0 + getReservesInUnderlying(bunniState.reserve0, bunniState.vault0),
            bunniState.rawBalance1 + getReservesInUnderlying(bunniState.reserve1, bunniState.vault1)
        );

        // compute total liquidity
        (totalLiquidity,,,,,,,) = queryLDF({
            key: key,
            sqrtPriceX96: updatedSqrtPriceX96,
            tick: updatedTick,
            arithmeticMeanTick: arithmeticMeanTick,
            ldf: bunniState.liquidityDensityFunction,
            ldfParams: bunniState.ldfParams,
            ldfState: newLdfState,
            balance0: balance0,
            balance1: balance1,
            idleBalance: bunniState.idleBalance
        });
    }

    /// @inheritdoc IBunniQuoter
    function getExcessLiquidity(PoolKey calldata key)
        external
        view
        returns (
            uint256 totalLiquidity,
            uint256 idleBalance,
            bool willRebalanceToken0,
            bool shouldRebalance,
            uint256 thresholdBalance,
            uint256 inputAmount,
            uint256 outputAmount
        )
    {
        PoolId id = key.toId();
        IBunniHook hook = IBunniHook(address(key.hooks));

        // load fresh state
        PoolState memory bunniState = hub.poolState(id);
        uint16 rebalanceThreshold;
        uint16 rebalanceMaxSlippage;
        {
            bytes memory hookParams = bunniState.hookParams;
            bytes32 firstWord;
            /// @solidity memory-safe-assembly
            assembly {
                firstWord := mload(add(hookParams, 32))
            }
            rebalanceThreshold = uint16(bytes2(firstWord << 184));
            rebalanceMaxSlippage = uint16(bytes2(firstWord << 200));
        }

        (uint160 updatedSqrtPriceX96, int24 updatedTick,,) = hook.slot0s(id);

        int24 arithmeticMeanTick;
        if (bunniState.twapSecondsAgo != 0) {
            arithmeticMeanTick = _getTwap(key, bunniState.twapSecondsAgo);
        }
        bytes32 newLdfState = hook.ldfStates(id);

        // get fresh token balances
        (uint256 balance0, uint256 balance1) = (
            bunniState.rawBalance0 + getReservesInUnderlying(bunniState.reserve0, bunniState.vault0),
            bunniState.rawBalance1 + getReservesInUnderlying(bunniState.reserve1, bunniState.vault1)
        );

        // compute total liquidity at spot price
        (totalLiquidity,,,,,,,) = queryLDF({
            key: key,
            sqrtPriceX96: updatedSqrtPriceX96,
            tick: updatedTick,
            arithmeticMeanTick: arithmeticMeanTick,
            ldf: bunniState.liquidityDensityFunction,
            ldfParams: bunniState.ldfParams,
            ldfState: newLdfState,
            balance0: balance0,
            balance1: balance1,
            idleBalance: bunniState.idleBalance
        });

        (idleBalance, willRebalanceToken0) = bunniState.idleBalance.fromIdleBalance();

        // compute target token densities of the excess liquidity after rebalancing
        // this is done by querying the LDF using a TWAP as the spot price to prevent manipulation
        uint160 rebalanceSpotPriceSqrtRatioX96 = TickMath.getSqrtPriceAtTick(arithmeticMeanTick);
        // totalDensity0X96 and totalDensity1X96 are the token densities of the excess liquidity
        // after rebalancing
        (, uint256 totalDensity0X96, uint256 totalDensity1X96,,,,,) = queryLDF({
            key: key,
            sqrtPriceX96: rebalanceSpotPriceSqrtRatioX96,
            tick: arithmeticMeanTick,
            arithmeticMeanTick: arithmeticMeanTick,
            ldf: bunniState.liquidityDensityFunction,
            ldfParams: bunniState.ldfParams,
            ldfState: newLdfState,
            balance0: 0,
            balance1: 0,
            idleBalance: IdleBalanceLibrary.ZERO
        });

        // compute the threshold balance
        // rebalance is triggered if idleBalance >= thresholdBalance
        thresholdBalance =
            totalLiquidity.fullMulX96(willRebalanceToken0 ? totalDensity0X96 : totalDensity1X96) / rebalanceThreshold;
        shouldRebalance = idleBalance != 0 && idleBalance >= thresholdBalance;

        // Let x be the idle balance, d be the input amount, and y be the output amount.
        // We want the resulting ratio (x - d) / y = r = totalDensityX / totalDensityY.
        // Given the price of the output token in terms of the input token, p, we have the following relationship:
        // (x - d) / (d / p) = r
        // => d = px / (p + r), y = d/p = x / (p + r)
        uint256 p; // price of output token in terms of the input token
        uint256 r; // desired ratio of the resulting input token amount to the output token amount
        if (willRebalanceToken0) {
            // zero for one
            uint256 rebalanceSpotPriceInvSqrtRatioX96 = TickMath.getSqrtPriceAtTick(-arithmeticMeanTick);
            p = rebalanceSpotPriceInvSqrtRatioX96.fullMulX96(rebalanceSpotPriceInvSqrtRatioX96);
            r = totalDensity0X96.fullMulDiv(Q96, totalDensity1X96);
        } else {
            // one for zero
            p = rebalanceSpotPriceSqrtRatioX96.fullMulX96(rebalanceSpotPriceSqrtRatioX96);
            r = totalDensity1X96.fullMulDiv(Q96, totalDensity0X96);
        }

        // apply slippage to price
        // normally slippage is applied to the price of the input token in terms of the output token, but here we use the inverse
        // so p := p / (1 - slippage)
        p = p.mulDiv(REBALANCE_MAX_SLIPPAGE_BASE, REBALANCE_MAX_SLIPPAGE_BASE - rebalanceMaxSlippage);

        // determine input & output
        inputAmount = idleBalance.mulDiv(p, p + r);
        outputAmount = idleBalance.mulDivUp(Q96, p + r);
    }

    /// -----------------------------------------------------------------------
    /// Internal functions
    /// -----------------------------------------------------------------------

    struct DepositLogicInputData {
        PoolState state;
        IBunniHub.DepositParams params;
        PoolKey poolKey;
        PoolId poolId;
        int24 currentTick;
        uint160 sqrtPriceX96;
    }

    struct DepositLogicReturnData {
        bool success;
        uint256 reserveAmount0;
        uint256 reserveAmount1;
        uint256 amount0;
        uint256 amount1;
        uint256 balance0;
        uint256 balance1;
    }

    /// @dev Separated to avoid stack too deep error
    function _depositLogic(DepositLogicInputData memory inputData)
        private
        view
        returns (DepositLogicReturnData memory returnData)
    {
        // query existing assets
        // assets = urrent tick tokens + reserve tokens + pool credits
        (uint256 reserveBalance0, uint256 reserveBalance1) = (
            getReservesInUnderlying(inputData.state.reserve0, inputData.state.vault0),
            getReservesInUnderlying(inputData.state.reserve1, inputData.state.vault1)
        );
        (returnData.balance0, returnData.balance1) =
            (inputData.state.rawBalance0 + reserveBalance0, inputData.state.rawBalance1 + reserveBalance1);

        // update TWAP oracle and optionally observe
        bool requiresLDF = returnData.balance0 == 0 && returnData.balance1 == 0;

        if (requiresLDF) {
            // use LDF to initialize token proportions

            // compute density
            bool useTwap = inputData.state.twapSecondsAgo != 0;
            int24 arithmeticMeanTick =
                useTwap ? queryTwap(inputData.params.poolKey, inputData.state.twapSecondsAgo) : int24(0);
            IBunniHook hook = IBunniHook(address(inputData.params.poolKey.hooks));
            bytes32 ldfState =
                inputData.state.ldfType == LDFType.DYNAMIC_AND_STATEFUL ? hook.ldfStates(inputData.poolId) : bytes32(0);
            (
                uint256 totalLiquidity,
                uint256 totalDensity0X96,
                uint256 totalDensity1X96,
                ,
                uint256 addedAmount0,
                uint256 addedAmount1,
                ,
            ) = queryLDF({
                key: inputData.params.poolKey,
                sqrtPriceX96: inputData.sqrtPriceX96,
                tick: inputData.currentTick,
                arithmeticMeanTick: arithmeticMeanTick,
                ldf: inputData.state.liquidityDensityFunction,
                ldfParams: inputData.state.ldfParams,
                ldfState: ldfState,
                balance0: inputData.params.amount0Desired, // use amount0Desired since we're initializing liquidity
                balance1: inputData.params.amount1Desired, // use amount1Desired since we're initializing liquidity
                idleBalance: IdleBalanceLibrary.ZERO // if balances are 0 then idle balance must also be 0
            });

            // compute token amounts to add
            (returnData.amount0, returnData.amount1) = (addedAmount0, addedAmount1);

            // sanity check against desired amounts
            // the amounts can exceed the desired amounts due to math errors
            if (
                (returnData.amount0 > inputData.params.amount0Desired)
                    || (returnData.amount1 > inputData.params.amount1Desired)
            ) {
                // scale down amounts and take minimum
                if (returnData.amount0 == 0) {
                    returnData.amount1 = inputData.params.amount1Desired;
                } else if (returnData.amount1 == 0) {
                    returnData.amount0 = inputData.params.amount0Desired;
                } else {
                    // both are non-zero
                    (returnData.amount0, returnData.amount1) = (
                        FixedPointMathLib.min(
                            inputData.params.amount0Desired,
                            returnData.amount0.mulDiv(inputData.params.amount1Desired, returnData.amount1)
                        ),
                        FixedPointMathLib.min(
                            inputData.params.amount1Desired,
                            returnData.amount1.mulDiv(inputData.params.amount0Desired, returnData.amount0)
                        )
                    );
                }
            }

            // ensure that the added amounts are not too small to mess with the shares math
            if (
                totalLiquidity == 0 || (returnData.amount0 < MIN_DEPOSIT_BALANCE_INCREASE && totalDensity0X96 != 0)
                    || (returnData.amount1 < MIN_DEPOSIT_BALANCE_INCREASE && totalDensity1X96 != 0)
            ) {
                return DepositLogicReturnData(false, 0, 0, 0, 0, 0, 0);
            }

            // update token amounts to deposit into vaults
            (returnData.reserveAmount0, returnData.reserveAmount1) = (
                returnData.amount0
                    - returnData.amount0.mulDiv(inputData.state.targetRawTokenRatio0, RAW_TOKEN_RATIO_BASE),
                returnData.amount1
                    - returnData.amount1.mulDiv(inputData.state.targetRawTokenRatio1, RAW_TOKEN_RATIO_BASE)
            );
        } else {
            // already initialized liquidity shape
            // simply add tokens at the current ratio
            // need to update: reserveAmount0, reserveAmount1, amount0, amount1

            // compute amount0 and amount1 such that the ratio is the same as the current ratio
            uint256 amount0Desired = inputData.params.amount0Desired;
            uint256 amount1Desired = inputData.params.amount1Desired;
            uint256 balance0 = returnData.balance0;
            uint256 balance1 = returnData.balance1;

            returnData.amount0 = balance1 == 0
                ? amount0Desired
                : FixedPointMathLib.min(amount0Desired, amount1Desired.mulDiv(balance0, balance1));
            returnData.amount1 = balance0 == 0
                ? amount1Desired
                : FixedPointMathLib.min(amount1Desired, amount0Desired.mulDiv(balance1, balance0));

            returnData.reserveAmount0 = balance0 == 0 ? 0 : returnData.amount0.mulDiv(reserveBalance0, balance0);
            returnData.reserveAmount1 = balance1 == 0 ? 0 : returnData.amount1.mulDiv(reserveBalance1, balance1);
        }

        // modify reserveAmount0 and reserveAmount1 using ERC4626::maxDeposit()
        {
            uint256 maxDeposit0;
            if (
                address(inputData.state.vault0) != address(0) && returnData.reserveAmount0 != 0
                    && returnData.reserveAmount0 > (maxDeposit0 = inputData.state.vault0.maxDeposit(address(this)))
            ) {
                returnData.reserveAmount0 = maxDeposit0;
            }
        }
        {
            uint256 maxDeposit1;
            if (
                address(inputData.state.vault1) != address(0) && returnData.reserveAmount1 != 0
                    && returnData.reserveAmount1 > (maxDeposit1 = inputData.state.vault1.maxDeposit(address(this)))
            ) {
                returnData.reserveAmount1 = maxDeposit1;
            }
        }

        returnData.success = true;
    }

    /// @dev Checks if the pool should surge based on the vault share price changes since the last swap.
    function _shouldSurgeFromVaults(
        PoolId id,
        IBunniHook hook,
        PoolState memory bunniState,
        DecodedHookParams memory hookParams,
        uint256 reserveBalance0,
        uint256 reserveBalance1
    ) private view returns (bool shouldSurge) {
        // only surge if at least one vault is set because otherwise total liquidity won't automatically increase
        // so there's no risk of being sandwiched
        if (address(bunniState.vault0) == address(0) && address(bunniState.vault1) == address(0)) return false;

        // compute share prices
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
        (bool prevSharePricesInitialized, uint120 prevSharePrice0, uint120 prevSharePrice1) =
            hook.vaultSharePricesAtLastSwap(id);
        return (
            prevSharePricesInitialized
                && (
                    dist(sharePrice0, prevSharePrice0) > prevSharePrice0 / hookParams.vaultSurgeThreshold0
                        || dist(sharePrice1, prevSharePrice1) > prevSharePrice1 / hookParams.vaultSurgeThreshold1
                )
        );
    }

    function _getTwap(PoolKey memory poolKey, uint24 twapSecondsAgo) internal view returns (int24 arithmeticMeanTick) {
        IBunniHook hook = IBunniHook(address(poolKey.hooks));
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapSecondsAgo;
        secondsAgos[1] = 0;
        int56[] memory tickCumulatives = hook.observe(poolKey, secondsAgos);
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        return int24(tickCumulativesDelta / int56(uint56(twapSecondsAgo)));
    }
}
