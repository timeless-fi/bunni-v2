// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IExtsload} from "@uniswap/v4-core/src/interfaces/IExtsload.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {IAmAmm} from "biddog/interfaces/IAmAmm.sol";

import "flood-contracts/src/interfaces/IZone.sol";
import "flood-contracts/src/interfaces/IFloodPlain.sol";

import {IERC1271} from "permit2/src/interfaces/IERC1271.sol";

import "../base/Constants.sol";
import "../base/SharedStructs.sol";
import {IOwnable} from "./IOwnable.sol";
import {Oracle} from "../lib/Oracle.sol";
import {IBunniHub} from "./IBunniHub.sol";
import {IBaseHook} from "./IBaseHook.sol";

/// @title BunniHook
/// @author zefram.eth
/// @notice Uniswap v4 hook responsible for handling swaps on Bunni. Implements auto-rebalancing
/// executed via FloodPlain. Uses am-AMM to recapture LVR & MEV.
interface IBunniHook is IBaseHook, IOwnable, IUnlockCallback, IERC1271, IAmAmm, IExtsload {
    /// -----------------------------------------------------------------------
    /// Events
    /// -----------------------------------------------------------------------

    /// @notice Emitted for swaps between currency0 and currency1
    /// @param id The abi encoded hash of the pool key struct for the pool that was modified
    /// @param sender The address that initiated the swap call, and that received the callback
    /// @param zeroForOne True if swapping token0 for token1, false otherwise
    /// @param inputAmount The input token amount
    /// @param outputAmount The output token amount
    /// @param sqrtPriceX96 The sqrt(price) of the pool after the swap, as a Q64.96
    /// @param tick The log base 1.0001 of the price of the pool after the swap
    /// @param fee The swap fee rate charged, 6 decimals
    /// @param totalLiquidity The total virtual liquidity of the pool during and after the swap
    event Swap(
        PoolId indexed id,
        address indexed sender,
        bool exactIn,
        bool zeroForOne,
        uint256 inputAmount,
        uint256 outputAmount,
        uint160 sqrtPriceX96,
        int24 tick,
        uint24 fee,
        uint256 totalLiquidity
    );
    event SetZone(IZone zone);
    event SetHookFeeRecipient(address hookFeeRecipient);
    event SetHookFeeModifier(uint32 indexed hookFeeModifier);
    event SetWithdrawalUnblocked(PoolId indexed id, bool unblocked);
    event ScheduleKChange(uint48 currentK, uint48 indexed newK, uint160 indexed activeBlock);
    event ClaimProtocolFees(Currency[] currencyList, address indexed recipient);
    event CuratorSetFeeRate(PoolId indexed id, uint16 indexed newFeeRate);
    event CuratorClaimFees(PoolId indexed id, address indexed recipient, uint256 feeAmount0, uint256 feeAmount1);

    /// -----------------------------------------------------------------------
    /// Structs and enums
    /// -----------------------------------------------------------------------

    /// @notice The state of a TWAP oracle for a given pool
    /// @member index The index of the last written observation for the pool
    /// @member cardinality The cardinality of the observations array for the pool
    /// @member cardinalityNext The cardinality target of the observations array for the pool, which will replace cardinality when enough observations are written
    /// @member intermediateObservation Used to maintain a min interval between observations
    struct ObservationState {
        uint32 index;
        uint32 cardinality;
        uint32 cardinalityNext;
        Oracle.Observation intermediateObservation;
    }

    /// @notice The arguments passed to the rebalance order prehook and posthook.
    /// @dev The hash of the hook args is used for validation in the prehook and posthook.
    /// @member key The pool key of the pool being rebalanced
    /// @member preHookArgs The prehook arguments
    /// @member postHookArgs The posthook arguments
    struct RebalanceOrderHookArgs {
        PoolKey key;
        RebalanceOrderPreHookArgs preHookArgs;
        RebalanceOrderPostHookArgs postHookArgs;
    }

    /// @notice The arguments passed to the rebalance order prehook.
    /// @member currency The currency to take from BunniHub and sell via the rebalance order
    /// @member amount The amount of currency to take from BunniHub and sell via the rebalance order
    struct RebalanceOrderPreHookArgs {
        Currency currency;
        uint256 amount;
    }

    /// @notice The arguments passed to the rebalance order posthook.
    /// @member currency The currency to receive from the rebalance order and give to BunniHub
    struct RebalanceOrderPostHookArgs {
        Currency currency;
    }

    /// -----------------------------------------------------------------------
    /// View functions
    /// -----------------------------------------------------------------------

    /// @notice Observe the given pool for the timestamps
    /// @param key The pool key
    /// @param secondsAgos The timestamps to observe
    /// @return tickCumulatives The tick cumulatives for the given timestamps
    function observe(PoolKey calldata key, uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives);

    /// @notice Validates if the given hook params are valid
    /// @param hookParams The hook params
    /// @return isValid True if the hook params are valid
    function isValidParams(bytes calldata hookParams) external view returns (bool);

    /// @notice The LDF state of a given pool. Used for evaluating the LDF.
    /// @param id The pool id
    /// @return The LDF state
    function ldfStates(PoolId id) external view returns (bytes32);

    /// @notice The slot0 state of a given pool
    /// @param id The pool id
    /// @return sqrtPriceX96
    /// @return tick The tick of the pool
    /// @return lastSwapTimestamp The timestamp of the last swap
    /// @return lastSurgeTimestamp The timestamp of the last surge
    function slot0s(PoolId id)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint32 lastSwapTimestamp, uint32 lastSurgeTimestamp);

    /// @notice Whether am-AMM is enabled for the given pool.
    function getAmAmmEnabled(PoolId id) external view returns (bool);

    /// @notice Whether liquidity can be withdrawn from the given pool.
    /// Currently used for pausing withdrawals when there is an active rebalance order.
    /// @param id The pool id
    /// @return Whether liquidity can be withdrawn from the given pool.
    function canWithdraw(PoolId id) external view returns (bool);

    /// -----------------------------------------------------------------------
    /// External functions
    /// -----------------------------------------------------------------------

    /// @notice Increase the cardinality target for the given pool
    /// @param key The pool key
    /// @param cardinalityNext The new cardinality target
    /// @return cardinalityNextOld The old cardinality target
    /// @return cardinalityNextNew The new cardinality target
    function increaseCardinalityNext(PoolKey calldata key, uint32 cardinalityNext)
        external
        returns (uint32 cardinalityNextOld, uint32 cardinalityNextNew);

    /// @notice Claim protocol fees for the given currency list.
    /// @param currencyList The list of currencies to claim fees for
    /// @return claimedAmounts The list of claimable fees for each currency
    function claimProtocolFees(Currency[] calldata currencyList) external returns (uint256[] memory claimedAmounts);

    /// -----------------------------------------------------------------------
    /// BunniHub functions
    /// -----------------------------------------------------------------------

    /// @notice Update the LDF state of the given pool. Only callable by BunniHub.
    /// @param id The pool id
    /// @param newState The new LDF state
    function updateLdfState(PoolId id, bytes32 newState) external;

    /// -----------------------------------------------------------------------
    /// Owner functions
    /// -----------------------------------------------------------------------

    /// @notice Set the FloodZone contract address. Only callable by the owner.
    /// @param zone The new FloodZone contract address
    function setZone(IZone zone) external;

    /// @notice Set the hook protocol fee recipient. Only callable by the owner.
    /// @param newProtocolFeeRecipient The new protocol fee recipient address
    function setHookFeeRecipient(address newProtocolFeeRecipient) external;

    /// @notice Set the hook fee params. Only callable by the owner.
    /// @param newHookFeeModifier The new hook fee modifier. 6 decimals.
    function setHookFeeModifier(uint32 newHookFeeModifier) external;

    /// @notice Set whether withdrawals are unblocked for the given pool. Only callable by the owner.
    /// @param id The pool id
    /// @param unblocked Whether withdrawals are unblocked for the given pool when a rebalance order is active
    function setWithdrawalUnblocked(PoolId id, bool unblocked) external;

    /// @notice Schedules a change in the K constant used in am-AMM. Only callable by the owner.
    /// @dev The new K should be greater than the current K. This corresponds to a decrease in block time.
    /// @param newK The new K constant
    /// @param activeBlock The block number at which the new K should take effect
    function scheduleKChange(uint48 newK, uint160 activeBlock) external;

    /// -----------------------------------------------------------------------
    /// Curator functions
    /// -----------------------------------------------------------------------

    /// @notice Sets the curator fee rate for the given pool. Only callable by the curator of the pool.
    /// @dev The curator fee rate is the percentage of swap fees that goes to the curator.
    /// The curator is the owner of the BunniToken, which is initially set to the pool deployer.
    /// @param id The pool id
    /// @param newFeeRate The new curator fee rate. 5 decimals.
    function curatorSetFeeRate(PoolId id, uint16 newFeeRate) external;

    /// @notice Claims the curator fees for the given pool. Only callable by the curator of the pool.
    /// @dev The curator is the owner of the BunniToken, which is initially set to the pool deployer.
    /// @param key The pool key
    /// @param recipient The recipient of the curator fees
    function curatorClaimFees(PoolKey calldata key, address recipient) external;

    /// -----------------------------------------------------------------------
    /// Rebalance functions
    /// -----------------------------------------------------------------------

    /// @notice Contains the logic for both the rebalance order prehook and posthook.
    /// Called by the FloodPlain contract prior to and after executing a rebalance order.
    /// Prehook should ensure the hook has at least `hookArgs.preHookArgs.amount` tokens of `hookArgs.preHookArgs.currency` upon return.
    /// Posthook should transfer any output tokens from the order to BunniHub (as ERC-6909 claim tokens) and update pool balances.
    /// @param isPreHook True if the hook is being called before the order execution (i.e. the prehook), false if it's being called after (i.e. the posthook)
    /// @param hookArgs The rebalance order hook arguments
    function rebalanceOrderHook(bool isPreHook, RebalanceOrderHookArgs calldata hookArgs) external;
}
