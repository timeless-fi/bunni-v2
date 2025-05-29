// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.15;

import "./BaseTest.sol";

import {ERC4626} from "solady/tokens/ERC4626.sol";
import {IAmAmm} from "biddog/interfaces/IAmAmm.sol";

contract CustomHook {
    function isValidParams(bytes calldata hookParams) external pure returns (bool) {
        return true;
    }

    function slot0s(PoolId id)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint32 lastSwapTimestamp, uint32 lastSurgeTimestamp)
    {
        int24 minTick = TickMath.MIN_TICK;
        (sqrtPriceX96, tick, lastSwapTimestamp, lastSurgeTimestamp) = (TickMath.getSqrtPriceAtTick(tick), tick, 0, 0);
    }

    function getBidWrite(PoolId id, bool isTopBid) external view returns (IAmAmm.Bid memory) {
        return IAmAmm.Bid({manager: address(0), blockIdx: 0, payload: 0, rent: 0, deposit: 0});
    }

    function getAmAmmEnabled(PoolId id) external view returns (bool) {
        return false;
    }

    function canWithdraw(PoolId id) external view returns (bool) {
        return true;
    }

    function afterInitialize(address caller, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        external
        returns (bytes4)
    {
        return BunniHook.afterInitialize.selector;
    }

    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        returns (bytes4, int256, uint24)
    {
        return (BunniHook.beforeSwap.selector, 0, 0);
    }

    function initiateAttack(address poolManager, PoolKey memory data, uint256 amountToSteal) external {}

    function disableReentrancyGuard(IBunniHub hub, PoolKey memory key) external {
        // Note: commented out because unlockForRebalance() no longer exists in BunniHub
        // hub.unlockForRebalance(key);
    }

    fallback() external payable {}
}

contract AttackerContract {
    using CurrencyLibrary for Currency;

    IBunniHub public hub;
    CustomHook public hook;
    PoolKey internal key;
    uint256 public deposit0;
    uint256 public deposit1;

    constructor(IBunniHub _hub) {
        hub = _hub;
    }

    function setHookAndKey(address _hook, PoolKey memory _key) external {
        hook = CustomHook(payable(_hook));
        key = _key;
    }

    function poolKey() public view returns (PoolKey memory) {
        return key;
    }

    // Implementation of IFulfiller interface
    function sourceConsideration(
        bytes28, /* selectorExtension */
        IFloodPlain.Order calldata order,
        address, /* caller */
        bytes calldata data
    ) external returns (uint256) {
        // first unlock the BunniHub from the malicious hook
        hook.disableReentrancyGuard(hub, poolKey());
        console2.log(ERC20Mock(order.consideration.token).balanceOf(address(this)));

        // now deposit liquidity into the target pool between rebalanceOrderPreHook and rebalanceOrderPostHook
        IBunniHub.DepositParams memory depositParams = abi.decode(data, (IBunniHub.DepositParams));
        uint256 value = depositParams.poolKey.currency0.isAddressZero() ? depositParams.amount0Desired : 0;
        (, deposit0, deposit1) = hub.deposit{value: value}(depositParams);

        ERC20Mock(order.consideration.token).approve(msg.sender, order.consideration.amount);
        console2.log(ERC20Mock(order.consideration.token).balanceOf(address(this)));
        return order.consideration.amount;
    }

    fallback() external payable {}
}

contract RebalanceAttackTest is BaseTest {
    using TickMath for *;
    using FullMathX96 for *;
    using SafeCastLib for *;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;

    function setUp() public override {
        super.setUp();
    }

    // Implementation of IFulfiller interface
    function sourceConsideration(
        bytes28, /* selectorExtension */
        IFloodPlain.Order calldata order,
        address, /* caller */
        bytes calldata data
    ) external returns (uint256) {
        (AttackerContract attacker, IBunniHub.DepositParams memory depositParams) =
            abi.decode(data, (AttackerContract, IBunniHub.DepositParams));

        return attacker.sourceConsideration(bytes28(0), order, address(this), abi.encode(depositParams));
    }

    function test_disableBunniHubReentrancyGuardPoC() public {
        // 1. Deploy the attacker contract
        AttackerContract attacker = new AttackerContract(hub);
        vm.startPrank(address(attacker));
        token0.approve(address(hub), type(uint256).max);
        token1.approve(address(hub), type(uint256).max);
        token0.approve(address(PERMIT2), type(uint256).max);
        token1.approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(address(token0), address(hub), type(uint160).max, type(uint48).max);
        PERMIT2.approve(address(token1), address(hub), type(uint160).max, type(uint48).max);
        vm.stopPrank();

        // 2. Create the malicious pool linked to the malicious hook
        bytes32 salt;
        unchecked {
            bytes memory creationCode = abi.encodePacked(type(CustomHook).creationCode);
            uint256 offset;
            while (true) {
                salt = bytes32(offset);
                address deployed = computeAddress(address(this), salt, creationCode);
                if (uint160(bytes20(deployed)) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS && deployed.code.length == 0) {
                    break;
                }
                offset++;
            }
        }

        address customHook = address(new CustomHook{salt: salt}());

        // whitelist the malicious hook to show that this attack is impossible even with a whitelisted hook
        hub.setHookWhitelist(BunniHook(payable(customHook)), true);

        (, PoolKey memory maliciousKey) = hub.deployBunniToken(
            IBunniHub.DeployBunniTokenParams({
                currency0: Currency.wrap(address(token0)),
                currency1: Currency.wrap(address(token1)),
                tickSpacing: TICK_SPACING,
                twapSecondsAgo: TWAP_SECONDS_AGO,
                liquidityDensityFunction: new MockLDF(address(hub), address(customHook), address(quoter)),
                hooklet: IHooklet(address(0)),
                ldfType: LDFType.DYNAMIC_AND_STATEFUL,
                ldfParams: bytes32(abi.encodePacked(ShiftMode.BOTH, int24(-3) * TICK_SPACING, int16(6), ALPHA)),
                hooks: BunniHook(payable(customHook)),
                hookParams: "",
                vault0: ERC4626(address(0)),
                vault1: ERC4626(address(0)),
                minRawTokenRatio0: 0.08e6,
                targetRawTokenRatio0: 0.1e6,
                maxRawTokenRatio0: 0.12e6,
                minRawTokenRatio1: 0.08e6,
                targetRawTokenRatio1: 0.1e6,
                maxRawTokenRatio1: 0.12e6,
                sqrtPriceX96: TickMath.getSqrtPriceAtTick(4),
                name: bytes32("MaliciousBunniToken"),
                symbol: bytes32("BAD-BUNNI-LP"),
                owner: address(this),
                metadataURI: "metadataURI",
                salt: bytes32(keccak256("malicious"))
            })
        );

        attacker.setHookAndKey(customHook, maliciousKey);

        // 3. Deposit into legitimate pool and bid in am-AMM auction
        (IBunniToken bunniToken, PoolKey memory key, MockLDF ldf) = test_rebalance_arb_setup();

        _makeDeposit(key, 1 ether, 1 ether, address(this), "");
        PoolId id = key.toId();
        bunniToken.approve(address(bunniHook), type(uint256).max);
        uint128 minRent = uint128(bunniToken.totalSupply() * MIN_RENT_MULTIPLIER / 1e18);
        uint128 rentDeposit = minRent * 2 days;
        bunniHook.bid(
            id, address(attacker), bytes6(abi.encodePacked(uint24(1e3), uint24(2e3))), minRent * 2, rentDeposit
        );

        // 4. Wait for attacker to become the am-AMM manager
        skipBlocks(K);
        assertEq(bunniHook.getBid(id, true).manager, address(attacker), "not manager yet");

        // 5. Execute re-entrancy to arbitrage rebalance of legitimate pool
        test_rebalance_arb_rebalance(bunniToken, key, ldf, address(attacker));
    }

    function test_rebalance_arb_setup() internal returns (IBunniToken bunniToken, PoolKey memory key, MockLDF ldf_) {
        ldf_ = new MockLDF(address(hub), address(bunniHook), address(quoter));
        bytes32 ldfParams = bytes32(abi.encodePacked(ShiftMode.BOTH, int24(-3) * TICK_SPACING, int16(6), ALPHA));
        ldf_.setMinTick(-30); // minTick of MockLDFs need initialization
        (bunniToken, key) = _deployPoolAndInitLiquidity(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            ERC4626(address(0)),
            ERC4626(address(0)),
            ldf_,
            ldfParams,
            abi.encodePacked(
                FEE_MIN,
                FEE_MAX,
                FEE_QUADRATIC_MULTIPLIER,
                FEE_TWAP_SECONDS_AGO,
                POOL_MAX_AMAMM_FEE,
                SURGE_HALFLIFE,
                SURGE_AUTOSTART_TIME,
                VAULT_SURGE_THRESHOLD_0,
                VAULT_SURGE_THRESHOLD_1,
                REBALANCE_THRESHOLD,
                REBALANCE_MAX_SLIPPAGE,
                REBALANCE_TWAP_SECONDS_AGO,
                REBALANCE_ORDER_TTL,
                true, // amAmmEnabled
                ORACLE_MIN_INTERVAL,
                MIN_RENT_MULTIPLIER
            )
        );
    }

    function test_rebalance_arb_rebalance(IBunniToken bunniToken, PoolKey memory key, MockLDF ldf_, address attacker)
        internal
    {
        uint256 swapAmount = 1e6;

        // shift liquidity to the right
        // the LDF will demand more token0, so we'll have too much of token1
        // the rebalance should swap from token1 to token0
        ldf_.setMinTick(-20);

        // make small swap to trigger rebalance
        _mint(key.currency0, address(this), swapAmount);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        vm.recordLogs();

        skip(100000);
        _swap(key, params, 0, "");

        // obtain the order from the logs
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory orderEtchedLog;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(floodPlain) && logs[i].topics[0] == IOnChainOrders.OrderEtched.selector) {
                orderEtchedLog = logs[i];
                break;
            }
        }
        IFloodPlain.SignedOrder memory signedOrder = abi.decode(orderEtchedLog.data, (IFloodPlain.SignedOrder));
        IFloodPlain.Order memory order = signedOrder.order;

        // prepare deposit data
        IBunniHub.DepositParams memory depositParams = IBunniHub.DepositParams({
            poolKey: key,
            amount0Desired: 1e18,
            amount1Desired: 1e18,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp,
            recipient: address(attacker),
            refundRecipient: address(attacker),
            vaultFee0: 0,
            vaultFee1: 0
        });

        uint256 amount0 = Currency.wrap(order.consideration.token) == key.currency0
            ? depositParams.amount0Desired + order.consideration.amount
            : depositParams.amount0Desired;
        uint256 amount1 = Currency.wrap(order.consideration.token) == key.currency1
            ? depositParams.amount1Desired + order.consideration.amount
            : depositParams.amount1Desired;
        _mint(key.currency0, address(attacker), amount0);
        _mint(key.currency1, address(attacker), amount1);

        // fulfill order
        // should revert due to reentrancy guard
        bytes memory data = abi.encode(depositParams);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuard__ReentrantCall.selector);
        floodPlain.fulfillOrder(signedOrder, address(attacker), data);
    }
}
