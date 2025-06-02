// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import "flood-contracts/src/interfaces/IFloodPlain.sol";

contract BasicBunniRebalancer is IUnlockCallback {
    using SafeCastLib for *;
    using SafeTransferLib for address;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable poolManager;
    IFloodPlain public immutable floodPlain;

    constructor(IPoolManager poolManager_, IFloodPlain floodPlain_) {
        poolManager = poolManager_;
        floodPlain = floodPlain_;
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "Not PoolManager");

        (IFloodPlain.SignedOrder memory package, PoolKey memory key) =
            abi.decode(data, (IFloodPlain.SignedOrder, PoolKey));

        // validate order
        require(PoolId.unwrap(key.toId()) == bytes32(package.signature), "Invalid signature");

        // swap with Bunni pool to obtain rebalance order swap consideration
        bool zeroForOne = package.order.consideration.token == Currency.unwrap(key.currency1);
        BalanceDelta swapDelta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: package.order.consideration.amount.toInt256(),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            bytes("")
        );
        poolManager.take(
            Currency.wrap(package.order.consideration.token), address(this), package.order.consideration.amount
        );

        // fulfill flood rebalance order and obtain rebalance order offer tokens
        package.order.consideration.token.safeApprove(address(floodPlain), package.order.consideration.amount);
        floodPlain.fulfillOrder(package);

        // use offer tokens to pay back PoolManager delta
        // any amount left over would be considered profit
        // in production there should be a function for withdrawing it, but this is a mock contract
        // so it doesn't matter
        address offerToken = package.order.offer[0].token;
        uint256 owedAmount = zeroForOne ? uint128(-swapDelta.amount0()) : uint128(-swapDelta.amount1());
        poolManager.sync(Currency.wrap(offerToken));
        offerToken.safeTransfer(address(poolManager), owedAmount);
        poolManager.settle();

        return bytes("");
    }

    function rebalance(IFloodPlain.SignedOrder calldata package, PoolKey calldata key) external {
        poolManager.unlock(abi.encode(package, key));
    }
}
