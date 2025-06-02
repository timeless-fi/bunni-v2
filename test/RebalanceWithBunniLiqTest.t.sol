// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.15;

import "./BaseTest.sol";
import "./mocks/BasicBunniRebalancer.sol";

import "flood-contracts/src/interfaces/IFloodPlain.sol";

contract RebalanceWithBunniLiqTest is BaseTest {
    BasicBunniRebalancer public rebalancer;

    function setUp() public override {
        super.setUp();

        rebalancer = new BasicBunniRebalancer(poolManager, floodPlain);
        zone.setIsWhitelisted(address(rebalancer), true);
    }

    function test_rebalance_withBunniLiq() public {
        MockLDF ldf_ = new MockLDF(address(hub), address(bunniHook), address(quoter));
        bytes32 ldfParams = bytes32(abi.encodePacked(ShiftMode.BOTH, int24(-3) * TICK_SPACING, int16(6), ALPHA));
        ldf_.setMinTick(-30);

        (, PoolKey memory key) = _deployPoolAndInitLiquidity(ldf_, ldfParams);

        // shift liquidity to the right
        // the LDF will demand more token0, so we'll have too much of token1
        ldf_.setMinTick(-20);

        // make swap to trigger rebalance
        uint256 swapAmount = 1e6;
        _mint(key.currency0, address(this), swapAmount);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        vm.recordLogs();
        _swap(key, params, 0, "");

        IdleBalance idleBalanceBefore = hub.idleBalance(key.toId());
        (uint256 balanceBefore, bool isToken0Before) = idleBalanceBefore.fromIdleBalance();
        assertGt(balanceBefore, 0, "idle balance should be non-zero");
        assertFalse(isToken0Before, "idle balance should be in token1");

        // obtain the order from the logs
        Vm.Log[] memory logs_ = vm.getRecordedLogs();
        Vm.Log memory orderEtchedLog;
        for (uint256 i = 0; i < logs_.length; i++) {
            if (logs_[i].emitter == address(floodPlain) && logs_[i].topics[0] == IOnChainOrders.OrderEtched.selector) {
                orderEtchedLog = logs_[i];
                break;
            }
        }
        IFloodPlain.SignedOrder memory signedOrder = abi.decode(orderEtchedLog.data, (IFloodPlain.SignedOrder));

        // wait for the surge fee to go down
        skip(9 minutes);

        // fulfill order using rebalancer
        rebalancer.rebalance(signedOrder, key);

        // rebalancer should have profits in token1
        assertGt(token1.balanceOf(address(rebalancer)), 0, "rebalancer should have profits");
    }
}
