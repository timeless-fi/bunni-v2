// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.15;

import {IAmAmm} from "biddog/interfaces/IAmAmm.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {ERC20CustomDecimalsMock} from "./mocks/ERC20CustomDecimalsMock.sol";
import {ERC4626CustomDecimalsMock} from "./mocks/ERC4626CustomDecimalsMock.sol";

import "./BaseTest.sol";
import {ERC4626TakeLessMock} from "./mocks/ERC4626TakeLessMock.sol";
import {UniformDistribution} from "../src/ldf/UniformDistribution.sol";
import {
    BunniHub__GracePeriodExpired,
    BunniHub__NoExpiredWithdrawal,
    BunniHub__VaultFeeIncorrect
} from "../src/base/Errors.sol";

contract BunniHubTest is BaseTest, IUnlockCallback {
    using TickMath for *;
    using FullMathX96 for *;
    using SafeCastLib for *;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;

    function setUp() public override {
        super.setUp();
    }

    function test_deposit(uint256 depositAmount0, uint256 depositAmount1) public {
        _execTestAcrossScenarios(_test_deposit, depositAmount0, depositAmount1, "deposit");
    }

    function _test_deposit(
        uint256 depositAmount0,
        uint256 depositAmount1,
        Currency currency0,
        Currency currency1,
        ERC4626 vault0_,
        ERC4626 vault1_,
        string memory snapLabel
    ) internal {
        depositAmount0 = bound(depositAmount0, 1e3, type(uint64).max);
        depositAmount1 = bound(depositAmount1, 1e3, type(uint64).max);
        (IBunniToken bunniToken, PoolKey memory key) =
            _deployPoolAndInitLiquidity(currency0, currency1, vault0_, vault1_);

        // make deposit
        uint256 vaultFee0 = (
            address(vault0_) == address(vault0WithFee) || address(vault0_) == address(vault1WithFee)
                || address(vault0_) == address(vaultWethWithFee)
        ) ? VAULT_FEE : (address(vault0_) == address(vault0TakeLess) ? 0.5e18 : 0);
        uint256 vaultFee1 = (
            address(vault1_) == address(vault0WithFee) || address(vault1_) == address(vault1WithFee)
                || address(vault1_) == address(vaultWethWithFee)
        ) ? VAULT_FEE : 0;
        (uint256 beforeBalance0, uint256 beforeBalance1) = hub.poolBalances(key.toId());
        (uint256 shares, uint256 amount0, uint256 amount1) =
            _makeDepositWithFee(key, depositAmount0, depositAmount1, address(this), vaultFee0, vaultFee1, snapLabel);
        (uint256 afterBalance0, uint256 afterBalance1) = hub.poolBalances(key.toId());

        // check return values
        assertApproxEqAbsDecimal(amount0, afterBalance0 - beforeBalance0, 1, DECIMALS, "amount0 incorrect");
        assertApproxEqAbsDecimal(amount1, afterBalance1 - beforeBalance1, 1, DECIMALS, "amount1 incorrect");
        assertEqDecimal(shares, bunniToken.balanceOf(address(this)), DECIMALS, "shares incorrect");
    }

    function test_deposit_msgValueNonZeroWhenNoETH() public {
        (, PoolKey memory key) = _deployPoolAndInitLiquidity();

        // make deposit with msg.value being non-zero
        // mint tokens
        uint256 depositAmount0 = 1 ether;
        uint256 depositAmount1 = 1 ether;
        _mint(key.currency0, address(this), depositAmount0);
        _mint(key.currency1, address(this), depositAmount1);

        // deposit tokens
        IBunniHub.DepositParams memory depositParams = IBunniHub.DepositParams({
            poolKey: key,
            amount0Desired: depositAmount0,
            amount1Desired: depositAmount1,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp,
            recipient: address(this),
            refundRecipient: address(this),
            vaultFee0: 0,
            vaultFee1: 0
        });
        vm.expectRevert(BunniHub__MsgValueNotZeroWhenPoolKeyHasNoNativeToken.selector);
        hub.deposit{value: 1 ether}(depositParams);
    }

    function test_withdraw(uint256 depositAmount0, uint256 depositAmount1) public {
        _execTestAcrossScenarios(_test_withdraw, depositAmount0, depositAmount1, "withdraw");
    }

    function _test_withdraw(
        uint256 depositAmount0,
        uint256 depositAmount1,
        Currency currency0,
        Currency currency1,
        ERC4626 vault0_,
        ERC4626 vault1_,
        string memory snapLabel
    ) internal {
        depositAmount0 = bound(depositAmount0, 1e6, type(uint64).max);
        depositAmount1 = bound(depositAmount1, 1e6, type(uint64).max);
        (IBunniToken bunniToken, PoolKey memory key) =
            _deployPoolAndInitLiquidity(currency0, currency1, vault0_, vault1_);

        // make deposit
        (uint256 shares, uint256 amount0, uint256 amount1) = _makeDepositWithFee({
            key_: key,
            depositAmount0: depositAmount0,
            depositAmount1: depositAmount1,
            depositor: address(this),
            vaultFee0: address(vault0_) == address(vault0WithFee) || address(vault0_) == address(vaultWethWithFee)
                ? 0.03e18
                : 0,
            vaultFee1: address(vault1_) == address(vault1WithFee) || address(vault1_) == address(vaultWethWithFee)
                ? 0.03e18
                : 0,
            snapLabel: ""
        });

        // withdraw
        IBunniHub.WithdrawParams memory withdrawParams = IBunniHub.WithdrawParams({
            poolKey: key,
            recipient: address(this),
            shares: shares,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp,
            useQueuedWithdrawal: false
        });
        IBunniHub hub_ = hub;
        (uint256 beforeBalance0, uint256 beforeBalance1) =
            (key.currency0.balanceOf(address(this)), key.currency1.balanceOf(address(this)));
        (uint256 withdrawAmount0, uint256 withdrawAmount1) = hub_.withdraw(withdrawParams);
        vm.snapshotGasLastCall(snapLabel);

        // check return values
        // withdraw amount less than original due to rounding
        assertApproxEqAbs(withdrawAmount0, amount0, 100, "withdrawAmount0 incorrect");
        assertApproxEqAbs(withdrawAmount1, amount1, 100, "withdrawAmount1 incorrect");

        // check token balances
        assertApproxEqAbs(
            key.currency0.balanceOf(address(this)) - beforeBalance0, withdrawAmount0, 10, "token0 balance incorrect"
        );
        assertApproxEqAbs(
            key.currency1.balanceOf(address(this)) - beforeBalance1, withdrawAmount1, 10, "token1 balance incorrect"
        );
        assertEqDecimal(bunniToken.balanceOf(address(this)), 0, DECIMALS, "didn't burn shares");
    }

    function test_withdraw_revertWhenRebalanceOrderIsActive() public {
        MockLDF ldf_ = new MockLDF(address(hub), address(bunniHook), address(quoter));
        ldf_.setMinTick(-30);

        // deploy pool and init liquidity
        Currency currency0 = Currency.wrap(address(token0));
        Currency currency1 = Currency.wrap(address(token1));
        (IBunniToken bunniToken, PoolKey memory key) =
            _deployPoolAndInitLiquidity(currency0, currency1, ERC4626(address(0)), ERC4626(address(0)), ldf_);

        // shift liquidity to the right
        // the LDF will demand more token0, so we'll have too much of token1
        // the rebalance should swap from token1 to token0
        ldf_.setMinTick(-20);

        // make small swap to trigger rebalance
        uint256 swapAmount = 1e6;
        _mint(key.currency0, address(this), swapAmount);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        _swap(key, params, 0, "");

        // try withdrawing liquidity
        IBunniHub.WithdrawParams memory withdrawParams = IBunniHub.WithdrawParams({
            poolKey: key,
            recipient: address(0x6969),
            shares: bunniToken.balanceOf(address(0x6969)),
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp,
            useQueuedWithdrawal: false
        });
        vm.startPrank(address(0x6969));
        vm.expectRevert(BunniHub__WithdrawalPaused.selector);
        hub.withdraw(withdrawParams);
        vm.stopPrank();

        // unblock withdrawals
        bunniHook.setWithdrawalUnblocked(key.toId(), true);

        // try withdrawing again
        vm.startPrank(address(0x6969));
        hub.withdraw(withdrawParams);
        assertEq(bunniToken.balanceOf(address(0x6969)), 0, "didn't withdraw");
        vm.stopPrank();
    }

    function test_queueWithdraw_happyPath(uint256 depositAmount0, uint256 depositAmount1) public {
        depositAmount0 = bound(depositAmount0, 1e16, type(uint64).max);
        depositAmount1 = bound(depositAmount1, 1e16, type(uint64).max);
        (IBunniToken bunniToken, PoolKey memory key) = _deployPoolAndInitLiquidity();

        // make deposit
        (uint256 shares,,) = _makeDepositWithFee({
            key_: key,
            depositAmount0: depositAmount0,
            depositAmount1: depositAmount1,
            depositor: address(this),
            vaultFee0: 0,
            vaultFee1: 0,
            snapLabel: ""
        });

        // bid in am-AMM auction
        PoolId id = key.toId();
        bunniToken.approve(address(bunniHook), type(uint256).max);
        uint128 minRent = uint128(bunniToken.totalSupply() * MIN_RENT_MULTIPLIER / 1e18);
        uint128 rentDeposit = minRent * 2 days;
        bunniHook.bid(id, address(this), bytes6(abi.encodePacked(uint24(1e3), uint24(2e3))), minRent * 2, rentDeposit);
        shares -= rentDeposit;

        // wait until address(this) is the manager
        skipBlocks(K);
        assertEq(bunniHook.getBid(id, true).manager, address(this), "not manager yet");

        // queue withdraw
        bunniToken.approve(address(hub), type(uint256).max);
        hub.queueWithdraw(IBunniHub.QueueWithdrawParams({poolKey: key, shares: shares.toUint200()}));
        assertEqDecimal(bunniToken.balanceOf(address(hub)), shares, DECIMALS, "didn't take shares");

        // wait a minute
        skip(1 minutes);

        // withdraw
        IBunniHub.WithdrawParams memory withdrawParams = IBunniHub.WithdrawParams({
            poolKey: key,
            recipient: address(this),
            shares: shares,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp,
            useQueuedWithdrawal: true
        });
        hub.withdraw(withdrawParams);
        assertEqDecimal(bunniToken.balanceOf(address(hub)), 0, DECIMALS, "didn't burn shares");
    }

    function test_queueWithdraw_fail_didNotQueue(uint256 depositAmount0, uint256 depositAmount1) public {
        depositAmount0 = bound(depositAmount0, 1e16, type(uint64).max);
        depositAmount1 = bound(depositAmount1, 1e16, type(uint64).max);
        (IBunniToken bunniToken, PoolKey memory key) = _deployPoolAndInitLiquidity();

        // make deposit
        (uint256 shares,,) = _makeDepositWithFee({
            key_: key,
            depositAmount0: depositAmount0,
            depositAmount1: depositAmount1,
            depositor: address(this),
            vaultFee0: 0,
            vaultFee1: 0,
            snapLabel: ""
        });

        // bid in am-AMM auction
        PoolId id = key.toId();
        bunniToken.approve(address(bunniHook), type(uint256).max);
        uint128 minRent = uint128(bunniToken.totalSupply() * MIN_RENT_MULTIPLIER / 1e18);
        uint128 rentDeposit = minRent * 2 days;
        bunniHook.bid(id, address(this), bytes6(abi.encodePacked(uint24(1e3), uint24(2e3))), minRent * 2, rentDeposit);
        shares -= rentDeposit;

        // wait until address(this) is the manager
        skipBlocks(K);
        assertEq(bunniHook.getBid(id, true).manager, address(this), "not manager yet");

        // withdraw
        IBunniHub.WithdrawParams memory withdrawParams = IBunniHub.WithdrawParams({
            poolKey: key,
            recipient: address(this),
            shares: shares,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp,
            useQueuedWithdrawal: false
        });
        vm.expectRevert(BunniHub__NeedToUseQueuedWithdrawal.selector);
        hub.withdraw(withdrawParams);

        withdrawParams = IBunniHub.WithdrawParams({
            poolKey: key,
            recipient: address(this),
            shares: shares,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp,
            useQueuedWithdrawal: true
        });
        vm.expectRevert(BunniHub__QueuedWithdrawalNonexistent.selector);
        hub.withdraw(withdrawParams);
    }

    function test_queueWithdraw_fail_notReady(uint256 depositAmount0, uint256 depositAmount1) public {
        depositAmount0 = bound(depositAmount0, 1e16, type(uint64).max);
        depositAmount1 = bound(depositAmount1, 1e16, type(uint64).max);
        (IBunniToken bunniToken, PoolKey memory key) = _deployPoolAndInitLiquidity();

        // make deposit
        (uint256 shares,,) = _makeDepositWithFee({
            key_: key,
            depositAmount0: depositAmount0,
            depositAmount1: depositAmount1,
            depositor: address(this),
            vaultFee0: 0,
            vaultFee1: 0,
            snapLabel: ""
        });

        // bid in am-AMM auction
        PoolId id = key.toId();
        bunniToken.approve(address(bunniHook), type(uint256).max);
        uint128 minRent = uint128(bunniToken.totalSupply() * MIN_RENT_MULTIPLIER / 1e18);
        uint128 rentDeposit = minRent * 2 days;
        bunniHook.bid(id, address(this), bytes6(abi.encodePacked(uint24(1e3), uint24(2e3))), minRent * 2, rentDeposit);
        shares -= rentDeposit;

        // wait until address(this) is the manager
        skipBlocks(K);
        assertEq(bunniHook.getBid(id, true).manager, address(this), "not manager yet");

        // queue withdraw
        bunniToken.approve(address(hub), type(uint256).max);
        hub.queueWithdraw(IBunniHub.QueueWithdrawParams({poolKey: key, shares: shares.toUint200()}));
        assertEqDecimal(bunniToken.balanceOf(address(hub)), shares, DECIMALS, "didn't take shares");

        // withdraw
        IBunniHub.WithdrawParams memory withdrawParams = IBunniHub.WithdrawParams({
            poolKey: key,
            recipient: address(this),
            shares: shares,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp,
            useQueuedWithdrawal: true
        });
        vm.expectRevert(BunniHub__QueuedWithdrawalNotReady.selector);
        hub.withdraw(withdrawParams);
    }

    function test_queueWithdraw_fail_gracePeriodExpired(uint256 depositAmount0, uint256 depositAmount1) public {
        depositAmount0 = bound(depositAmount0, 1e16, type(uint64).max);
        depositAmount1 = bound(depositAmount1, 1e16, type(uint64).max);
        (IBunniToken bunniToken, PoolKey memory key) = _deployPoolAndInitLiquidity();

        // make deposit
        (uint256 shares,,) = _makeDepositWithFee({
            key_: key,
            depositAmount0: depositAmount0,
            depositAmount1: depositAmount1,
            depositor: address(this),
            vaultFee0: 0,
            vaultFee1: 0,
            snapLabel: ""
        });

        // bid in am-AMM auction
        PoolId id = key.toId();
        bunniToken.approve(address(bunniHook), type(uint256).max);
        uint128 minRent = uint128(bunniToken.totalSupply() * MIN_RENT_MULTIPLIER / 1e18);
        uint128 rentDeposit = minRent * 2 days;
        bunniHook.bid(id, address(this), bytes6(abi.encodePacked(uint24(1e3), uint24(2e3))), minRent * 2, rentDeposit);
        shares -= rentDeposit;

        // wait until address(this) is the manager
        skipBlocks(K);
        assertEq(bunniHook.getBid(id, true).manager, address(this), "not manager yet");

        // queue withdraw
        bunniToken.approve(address(hub), type(uint256).max);
        hub.queueWithdraw(IBunniHub.QueueWithdrawParams({poolKey: key, shares: shares.toUint200()}));
        assertEqDecimal(bunniToken.balanceOf(address(hub)), shares, DECIMALS, "didn't take shares");

        // wait an hour
        skip(1 hours);

        // withdraw
        IBunniHub.WithdrawParams memory withdrawParams = IBunniHub.WithdrawParams({
            poolKey: key,
            recipient: address(this),
            shares: shares,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1 hours,
            useQueuedWithdrawal: true
        });
        vm.expectRevert(BunniHub__GracePeriodExpired.selector);
        hub.withdraw(withdrawParams);

        // queue withdraw again to refresh lock
        hub.queueWithdraw(IBunniHub.QueueWithdrawParams({poolKey: key, shares: 0}));

        // wait a minute
        skip(1 minutes);

        // withdraw
        hub.withdraw(withdrawParams);

        // check balances
        assertEqDecimal(bunniToken.balanceOf(address(hub)), 0, DECIMALS, "didn't burn shares");
    }

    function test_multicall() external {
        Currency currency0 = CurrencyLibrary.ADDRESS_ZERO;
        Currency currency1 = Currency.wrap(address(token0));
        (, PoolKey memory key) = _deployPoolAndInitLiquidity(currency0, currency1);

        _mint(currency0, address(this), 3 ether);
        _mint(currency1, address(this), 3 ether);

        address[] memory targets = new address[](2);
        targets[0] = address(hub);
        targets[1] = address(hub);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(
            IBunniHub.deposit.selector,
            IBunniHub.DepositParams({
                poolKey: key,
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                recipient: address(this),
                refundRecipient: address(this),
                vaultFee0: 0,
                vaultFee1: 0
            })
        );
        data[1] = abi.encodeWithSelector(
            IBunniHub.deposit.selector,
            IBunniHub.DepositParams({
                poolKey: key,
                amount0Desired: 2 ether,
                amount1Desired: 2 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                recipient: address(this),
                refundRecipient: address(this),
                vaultFee0: 0,
                vaultFee1: 0
            })
        );

        uint256[] memory values = new uint256[](2);
        values[0] = 1 ether;
        values[1] = 2 ether;

        (uint256 beforeBalance0, uint256 beforeBalance1) =
            (currency0.balanceOf(address(this)), currency1.balanceOf(address(this)));
        bytes[] memory results = MulticallerWithSender(payable(LibMulticaller.MULTICALLER_WITH_SENDER))
            .aggregateWithSender{value: 3 ether}(targets, data, values);
        (, uint256 amount0Call0, uint256 amount1Call0) = abi.decode(results[0], (uint256, uint256, uint256));
        (, uint256 amount0Call1, uint256 amount1Call1) = abi.decode(results[1], (uint256, uint256, uint256));

        // tokens taken should match sum of returned values
        assertEq(
            beforeBalance0,
            amount0Call0 + amount0Call1 + currency0.balanceOf(address(this)),
            "amount0Call0 + amount0Call1 != amount taken"
        );
        assertEq(
            beforeBalance1,
            amount1Call0 + amount1Call1 + currency1.balanceOf(address(this)),
            "amount1Call0 + amount1Call1 != amount taken"
        );
    }

    function test_deployMultiplePoolsInSameSubspace() external {
        for (uint256 i; i < 10; i++) {
            Currency currency0 = CurrencyLibrary.ADDRESS_ZERO;
            Currency currency1 = Currency.wrap(address(token0));
            (, PoolKey memory key) = _deployPoolAndInitLiquidity(currency0, currency1, bytes32(i));
            assertEq(key.fee, i, "nonce not increasing");
        }
    }

    function test_deployBunniToken(
        string calldata name,
        string calldata symbol,
        address owner,
        string calldata metadataURI,
        IHooklet hooklet_
    ) external {
        vm.assume(
            bytes(name).length <= 32 && bytes(symbol).length <= 32
                && !HookletLib.hasPermission(hooklet_, HookletLib.BEFORE_INITIALIZE_FLAG)
                && !HookletLib.hasPermission(hooklet_, HookletLib.AFTER_INITIALIZE_FLAG)
        );

        Currency currency0 = Currency.wrap(address(token0));
        Currency currency1 = Currency.wrap(address(token1));
        bytes32 ldfParams = bytes32(abi.encodePacked(ShiftMode.BOTH, int24(-3) * TICK_SPACING, int16(6), ALPHA));
        bytes memory hookParams = abi.encodePacked(
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
        );

        bytes32 name_ = bytes32(bytes(name));
        bytes32 symbol_ = bytes32(bytes(symbol));

        (IBunniToken bunniToken, PoolKey memory key) = hub.deployBunniToken(
            IBunniHub.DeployBunniTokenParams({
                currency0: currency0,
                currency1: currency1,
                tickSpacing: TICK_SPACING,
                twapSecondsAgo: TWAP_SECONDS_AGO,
                liquidityDensityFunction: ldf,
                hooklet: hooklet_,
                ldfType: LDFType.DYNAMIC_AND_STATEFUL,
                ldfParams: ldfParams,
                hooks: bunniHook,
                hookParams: hookParams,
                vault0: vault0,
                vault1: ERC4626(address(0)),
                minRawTokenRatio0: 0.08e6,
                targetRawTokenRatio0: 0.1e6,
                maxRawTokenRatio0: 0.12e6,
                minRawTokenRatio1: 0.08e6,
                targetRawTokenRatio1: 0.1e6,
                maxRawTokenRatio1: 0.12e6,
                sqrtPriceX96: TickMath.getSqrtPriceAtTick(4),
                name: name_,
                symbol: symbol_,
                owner: owner,
                metadataURI: metadataURI,
                salt: bytes32(0)
            })
        );
        assertEq(bunniToken.owner(), owner, "owner not set");
        assertEq(bunniToken.metadataURI(), metadataURI, "metadataURI not set");
        assertEq(address(bunniToken.hub()), address(hub), "hub not set");
        assertEq(Currency.unwrap(bunniToken.token0()), Currency.unwrap(currency0), "token0 not set");
        assertEq(Currency.unwrap(bunniToken.token1()), Currency.unwrap(currency1), "token1 not set");
        assertEq(bunniToken.name(), string(abi.encodePacked(name_)), "name not set");
        assertEq(bunniToken.symbol(), string(abi.encodePacked(symbol_)), "symbol not set");
        assertEq(address(bunniToken.poolManager()), address(poolManager), "poolManager not set");
        PoolKey memory bunniTokenKey = bunniToken.poolKey();
        assertEq(
            Currency.unwrap(bunniTokenKey.currency0), Currency.unwrap(key.currency0), "bunniToken key.currency0 not set"
        );
        assertEq(
            Currency.unwrap(bunniTokenKey.currency1), Currency.unwrap(key.currency1), "bunniToken key.currency1 not set"
        );
        assertEq(bunniTokenKey.fee, key.fee, "bunniToken key.fee not set");
        assertEq(bunniTokenKey.tickSpacing, key.tickSpacing, "bunniToken key.tickSpacing not set");
        assertEq(address(bunniTokenKey.hooks), address(bunniHook), "bunniToken key.hooks not set");
        assertEq(address(bunniToken.hooklet()), address(hooklet_), "bunniToken hooklet not set");
        assertEq(Currency.unwrap(key.currency0), Currency.unwrap(currency0), "currency0 not set");
        assertEq(Currency.unwrap(key.currency1), Currency.unwrap(currency1), "currency1 not set");
        assertEq(key.tickSpacing, TICK_SPACING, "tickSpacing not set");
        assertEq(address(key.hooks), address(bunniHook), "hooks not set");

        // verify pool state
        PoolId id = key.toId();
        PoolState memory state = hub.poolState(id);
        assertEq(address(state.liquidityDensityFunction), address(ldf), "ldf incorrect");
        assertEq(address(state.bunniToken), address(bunniToken), "bunniToken incorrect");
        assertEq(state.twapSecondsAgo, TWAP_SECONDS_AGO, "twapSecondsAgo incorrect");
        assertEq(state.ldfParams, ldfParams, "ldfParams incorrect");
        assertEq(state.hookParams, hookParams, "hookParams incorrect");
        assertEq(hub.hookParams(id), hookParams, "hub.hookParams() incorrect");
        assertEq(address(state.vault0), address(vault0), "vault0 incorrect");
        assertEq(address(state.vault1), address(0), "vault1 incorrect");
        assertEq(uint8(state.ldfType), uint8(LDFType.DYNAMIC_AND_STATEFUL), "ldfType incorrect");
        assertEq(state.minRawTokenRatio0, 0.08e6, "minRawTokenRatio0 incorrect");
        assertEq(state.targetRawTokenRatio0, 0.1e6, "targetRawTokenRatio0 incorrect");
        assertEq(state.maxRawTokenRatio0, 0.12e6, "maxRawTokenRatio0 incorrect");
        assertEq(state.minRawTokenRatio1, 0.08e6, "minRawTokenRatio1 incorrect");
        assertEq(state.targetRawTokenRatio1, 0.1e6, "targetRawTokenRatio1 incorrect");
        assertEq(state.maxRawTokenRatio1, 0.12e6, "maxRawTokenRatio1 incorrect");
        assertEq(state.currency0Decimals, token0.decimals(), "currency0Decimals incorrect");
        assertEq(state.currency1Decimals, token1.decimals(), "currency1Decimals incorrect");
        assertEq(state.vault0Decimals, vault0.decimals(), "vault0Decimals incorrect");
        assertEq(state.vault1Decimals, 0, "vault1Decimals incorrect");
        assertEq(address(state.hooklet), address(hooklet_), "hooklet incorrect");
        assertEq(address(hub.hookletOfPool(id)), address(hooklet_), "hub.hookletOfPool() incorrect");

        // verify decoded hookParams
        DecodedHookParams memory p = BunniHookLogic.decodeHookParams(hookParams);
        assertEq(p.feeMin, FEE_MIN, "feeMin incorrect");
        assertEq(p.feeMax, FEE_MAX, "feeMax incorrect");
        assertEq(p.feeQuadraticMultiplier, FEE_QUADRATIC_MULTIPLIER, "feeQuadraticMultiplier incorrect");
        assertEq(p.feeTwapSecondsAgo, FEE_TWAP_SECONDS_AGO, "feeTwapSecondsAgo incorrect");
        assertEq(p.surgeFeeHalfLife, SURGE_HALFLIFE, "surgeFeeHalfLife incorrect");
        assertEq(p.surgeFeeAutostartThreshold, SURGE_AUTOSTART_TIME, "surgeFeeAutostartThreshold incorrect");
        assertEq(p.vaultSurgeThreshold0, VAULT_SURGE_THRESHOLD_0, "vaultSurgeThreshold0 incorrect");
        assertEq(p.vaultSurgeThreshold1, VAULT_SURGE_THRESHOLD_1, "vaultSurgeThreshold1 incorrect");
        assertEq(p.rebalanceThreshold, REBALANCE_THRESHOLD, "rebalanceThreshold incorrect");
        assertEq(p.rebalanceMaxSlippage, REBALANCE_MAX_SLIPPAGE, "rebalanceMaxSlippage incorrect");
        assertEq(p.rebalanceTwapSecondsAgo, REBALANCE_TWAP_SECONDS_AGO, "rebalanceTwapSecondsAgo incorrect");
        assertEq(p.rebalanceOrderTTL, REBALANCE_ORDER_TTL, "rebalanceOrderTTL incorrect");
        assertTrue(p.amAmmEnabled, "amAmmEnabled incorrect");
        assertEq(p.oracleMinInterval, ORACLE_MIN_INTERVAL, "oracleMinInterval incorrect");
        assertEq(p.maxAmAmmFee, POOL_MAX_AMAMM_FEE, "maxAmAmmFee incorrect");
        assertEq(p.minRentMultiplier, MIN_RENT_MULTIPLIER, "minRentMultiplier incorrect");
    }

    function test_revert_deployBunniToken_vaultDecimalsTooSmall() public {
        bytes32 ldfParams = bytes32(abi.encodePacked(ShiftMode.BOTH, int24(-3) * TICK_SPACING, int16(6), ALPHA));
        bytes memory hookParams = abi.encodePacked(
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
        );

        // 18 + vaultDecimals < tokenDecimals
        // thus it should revert
        ERC20CustomDecimalsMock token = new ERC20CustomDecimalsMock(36);
        ERC4626CustomDecimalsMock vault = new ERC4626CustomDecimalsMock(token, 6);
        vm.expectRevert(BunniHub__VaultDecimalsTooSmall.selector);
        hub.deployBunniToken(
            IBunniHub.DeployBunniTokenParams({
                currency0: Currency.wrap(address(token)),
                currency1: Currency.wrap(address(token1)),
                tickSpacing: TICK_SPACING,
                twapSecondsAgo: TWAP_SECONDS_AGO,
                liquidityDensityFunction: ldf,
                hooklet: IHooklet(address(0)),
                ldfType: LDFType.DYNAMIC_AND_STATEFUL,
                ldfParams: ldfParams,
                hooks: bunniHook,
                hookParams: hookParams,
                vault0: vault,
                vault1: vault1,
                minRawTokenRatio0: 0.08e6,
                targetRawTokenRatio0: 0.1e6,
                maxRawTokenRatio0: 0.12e6,
                minRawTokenRatio1: 0.08e6,
                targetRawTokenRatio1: 0.1e6,
                maxRawTokenRatio1: 0.12e6,
                sqrtPriceX96: uint160(Q96),
                name: "BunniToken",
                symbol: "BUNNI",
                owner: address(this),
                metadataURI: "",
                salt: bytes32(0)
            })
        );
    }

    function test_DoS_pool() public {
        // Deployment data
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);
        Currency currency0 = Currency.wrap(address(token0));
        Currency currency1 = Currency.wrap(address(token1));
        bytes32 ldfParams = bytes32(abi.encodePacked(ShiftMode.BOTH, int24(-3) * TICK_SPACING, int16(6), ALPHA));
        bytes memory hookParams = abi.encodePacked(
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
            true,
            ORACLE_MIN_INTERVAL,
            MIN_RENT_MULTIPLIER
        );
        bytes32 salt;
        unchecked {
            bytes memory creationCode = type(HookletMock).creationCode;
            for (uint256 offset; offset < 100000; offset++) {
                salt = bytes32(offset);
                address deployed = computeAddress(address(this), salt, creationCode);
                if (
                    uint160(bytes20(deployed)) & HookletLib.ALL_FLAGS_MASK == HookletLib.ALL_FLAGS_MASK
                        && deployed.code.length == 0
                ) {
                    break;
                }
            }
        }
        HookletMock hooklet = new HookletMock{salt: salt}();

        // Deploy BunniToken
        (, PoolKey memory key) = hub.deployBunniToken(
            IBunniHub.DeployBunniTokenParams({
                currency0: currency0,
                currency1: currency1,
                tickSpacing: TICK_SPACING,
                twapSecondsAgo: TWAP_SECONDS_AGO,
                liquidityDensityFunction: ldf,
                hooklet: hooklet,
                ldfType: LDFType.DYNAMIC_AND_STATEFUL,
                ldfParams: ldfParams,
                hooks: bunniHook,
                hookParams: hookParams,
                vault0: ERC4626(address(vault0)),
                vault1: ERC4626(address(vault1)),
                minRawTokenRatio0: 0.08e6,
                targetRawTokenRatio0: 0.1e6,
                maxRawTokenRatio0: 0.12e6,
                minRawTokenRatio1: 0.08e6,
                targetRawTokenRatio1: 0.1e6,
                maxRawTokenRatio1: 0.12e6,
                sqrtPriceX96: sqrtPriceX96,
                name: bytes32("BunniToken"),
                symbol: bytes32("BUNNI-LP"),
                owner: address(this),
                metadataURI: "metadataURI",
                salt: salt
            })
        );

        // Mint shares using 1 wei of each token
        // Should revert due to the amounts being too small
        _mint(currency0, address(this), 1);
        _mint(currency1, address(this), 1);
        vm.expectRevert(BunniHub__DepositAmountTooSmall.selector);
        hub.deposit(
            IBunniHub.DepositParams({
                poolKey: key,
                amount0Desired: 1,
                amount1Desired: 1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                recipient: address(this),
                refundRecipient: address(this),
                vaultFee0: 0,
                vaultFee1: 0
            })
        );
    }

    function test_idleBalance_startAtZero() public {
        (, PoolKey memory key) = _deployPoolAndInitLiquidity();

        // idle balance should be 0
        IdleBalance idleBalance = hub.idleBalance(key.toId());
        (uint256 balance,) = idleBalance.fromIdleBalance();
        assertEq(balance, 0, "idle balance not zero at start");
    }

    function test_idleBalance_ldfShiftUpdatesIdleBalance() public {
        MockLDF ldf_ = new MockLDF(address(hub), address(bunniHook), address(quoter));
        bytes32 ldfParams = bytes32(abi.encodePacked(ShiftMode.BOTH, int24(-3) * TICK_SPACING, int16(6), ALPHA));
        ldf_.setMinTick(-30);

        (, PoolKey memory key) = _deployPoolAndInitLiquidity(ldf_, ldfParams);

        // shift liquidity to the right
        // the LDF will demand more token0, so we'll have too much of token1
        ldf_.setMinTick(-20);

        // make swap to update state
        uint256 swapAmount = 1e6;
        _mint(key.currency0, address(this), swapAmount);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        _swap(key, params, 0, "");

        // idle balance should be non-zero and in token1
        IdleBalance idleBalance = hub.idleBalance(key.toId());
        (uint256 balance, bool isToken0) = idleBalance.fromIdleBalance();
        assertGt(balance, 0, "idle balance should be non-zero");
        assertFalse(isToken0, "idle balance should be in token1");
    }

    function test_pauseFlags(uint8 pauseFlags) public {
        (, PoolKey memory key) = _deployPoolAndInitLiquidity();

        hub.setPauseFlags(pauseFlags);

        if (pauseFlags & (1 << 0) != 0) {
            // deposit() is paused
            _mint(key.currency0, address(this), 1e18);
            _mint(key.currency1, address(this), 1e18);
            IBunniHub.DepositParams memory depositParams = IBunniHub.DepositParams({
                poolKey: key,
                amount0Desired: 1e18,
                amount1Desired: 1e18,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                recipient: address(this),
                refundRecipient: address(this),
                vaultFee0: 0,
                vaultFee1: 0
            });
            vm.expectRevert(BunniHub__Paused.selector);
            hub.deposit(depositParams);
        }

        if (pauseFlags & (1 << 1) != 0) {
            // queueWithdraw() is paused
            IBunniHub.QueueWithdrawParams memory queueWithdrawParams =
                IBunniHub.QueueWithdrawParams({poolKey: key, shares: 1e18});
            vm.expectRevert(BunniHub__Paused.selector);
            hub.queueWithdraw(queueWithdrawParams);
        }

        if (pauseFlags & (1 << 2) != 0) {
            // withdraw() is paused
            IBunniHub.WithdrawParams memory withdrawParams = IBunniHub.WithdrawParams({
                poolKey: key,
                recipient: address(this),
                shares: 1e18,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                useQueuedWithdrawal: false
            });
            vm.expectRevert(BunniHub__Paused.selector);
            hub.withdraw(withdrawParams);
        }

        if (pauseFlags & (1 << 3) != 0) {
            // deployBunniToken() is paused
            vm.expectRevert(BunniHub__Paused.selector);
            hub.deployBunniToken(
                IBunniHub.DeployBunniTokenParams({
                    currency0: key.currency0,
                    currency1: key.currency1,
                    tickSpacing: TICK_SPACING,
                    twapSecondsAgo: 7 days,
                    liquidityDensityFunction: ldf,
                    hooklet: IHooklet(address(0)),
                    ldfType: LDFType.DYNAMIC_AND_STATEFUL,
                    ldfParams: bytes32(0),
                    hooks: bunniHook,
                    hookParams: bytes(""),
                    vault0: ERC4626(address(0)),
                    vault1: ERC4626(address(0)),
                    minRawTokenRatio0: 0.08e6,
                    targetRawTokenRatio0: 0.1e6,
                    maxRawTokenRatio0: 0.12e6,
                    minRawTokenRatio1: 0.08e6,
                    targetRawTokenRatio1: 0.1e6,
                    maxRawTokenRatio1: 0.12e6,
                    sqrtPriceX96: uint160(Q96),
                    name: "BunniToken",
                    symbol: "BUNNI-LP",
                    owner: address(this),
                    metadataURI: "metadataURI",
                    salt: bytes32(0)
                })
            );
        }

        if (pauseFlags & (1 << 4) != 0) {
            // hookHandleSwap() is paused
            vm.expectRevert(BunniHub__Paused.selector);
            hub.hookHandleSwap(key, true, 0, 0, false);
        }

        if (pauseFlags & (1 << 5) != 0) {
            // hookSetIdleBalance() is paused
            vm.expectRevert(BunniHub__Paused.selector);
            hub.hookSetIdleBalance(key, IdleBalanceLibrary.ZERO);
        }

        if (pauseFlags & (1 << 6) != 0) {
            // lockForRebalance() is paused
            vm.expectRevert(BunniHub__Paused.selector);
            hub.lockForRebalance(key);
        }
    }

    function test_unpauseFuse() external {
        hub.setPauseFlags(type(uint8).max);
        hub.burnPauseFuse();

        // deploy pool
        (IBunniToken bunniToken, PoolKey memory key) = _deployPoolAndInitLiquidity();

        // deposit() is not paused
        _mint(key.currency0, address(this), 1e18);
        _mint(key.currency1, address(this), 1e18);
        IBunniHub.DepositParams memory depositParams = IBunniHub.DepositParams({
            poolKey: key,
            amount0Desired: 1e18,
            amount1Desired: 1e18,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp,
            recipient: address(this),
            refundRecipient: address(this),
            vaultFee0: 0,
            vaultFee1: 0
        });
        hub.deposit(depositParams);

        // queueWithdraw() is not paused
        IBunniHub.QueueWithdrawParams memory queueWithdrawParams =
            IBunniHub.QueueWithdrawParams({poolKey: key, shares: 1});
        bunniToken.approve(address(hub), type(uint256).max);
        hub.queueWithdraw(queueWithdrawParams);

        // withdraw() is not paused
        IBunniHub.WithdrawParams memory withdrawParams = IBunniHub.WithdrawParams({
            poolKey: key,
            recipient: address(this),
            shares: 1,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp,
            useQueuedWithdrawal: false
        });
        hub.withdraw(withdrawParams);

        // deployBunniToken() is not paused
        hub.deployBunniToken(
            IBunniHub.DeployBunniTokenParams({
                currency0: key.currency0,
                currency1: key.currency1,
                tickSpacing: TICK_SPACING,
                twapSecondsAgo: 7 days,
                liquidityDensityFunction: ldf,
                hooklet: IHooklet(address(0)),
                ldfType: LDFType.DYNAMIC_AND_STATEFUL,
                ldfParams: bytes32(abi.encodePacked(ShiftMode.BOTH, int24(-3) * TICK_SPACING, int16(6), ALPHA)),
                hooks: bunniHook,
                hookParams: abi.encodePacked(
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
                ),
                vault0: ERC4626(address(0)),
                vault1: ERC4626(address(0)),
                minRawTokenRatio0: 0.08e6,
                targetRawTokenRatio0: 0.1e6,
                maxRawTokenRatio0: 0.12e6,
                minRawTokenRatio1: 0.08e6,
                targetRawTokenRatio1: 0.1e6,
                maxRawTokenRatio1: 0.12e6,
                sqrtPriceX96: uint160(Q96),
                name: "BunniToken",
                symbol: "BUNNI-LP",
                owner: address(this),
                metadataURI: "metadataURI",
                salt: bytes32(uint256(1234))
            })
        );

        vm.startPrank(address(bunniHook));

        // hookHandleSwap() is not paused
        hub.hookHandleSwap(key, true, 0, 0, false);

        // hookSetIdleBalance() is not paused
        hub.hookSetIdleBalance(key, IdleBalanceLibrary.ZERO);

        // lockForRebalance() is not paused
        hub.lockForRebalance(key);

        vm.stopPrank();
    }

    function test_pause_authChecks(uint8 pauseFlags) external {
        // owner can set pauseFlags
        hub.setPauseFlags(pauseFlags);
        (uint8 pauseFlagsUpdated,) = hub.getPauseStatus();
        assertEq(pauseFlagsUpdated, pauseFlags, "pauseFlags not set by owner");
        hub.setPauseFlags(0); // reset

        // pauser can set pauseFlags
        address guy = makeAddr("guy");
        hub.setPauser(guy, true);
        assertTrue(hub.isPauser(guy), "pauser not set");
        vm.prank(guy);
        hub.setPauseFlags(pauseFlags);
        (pauseFlagsUpdated,) = hub.getPauseStatus();
        assertEq(pauseFlagsUpdated, pauseFlags, "pauseFlags not set by pauser");
        hub.setPauseFlags(0); // reset

        // others cannot set pauseFlags
        address others = makeAddr("others");
        vm.prank(others);
        vm.expectRevert(BunniHub__Unauthorized.selector);
        hub.setPauseFlags(pauseFlags);

        // guy cannot set pauseFlags after revoking pauser role
        hub.setPauser(guy, false);
        assertFalse(hub.isPauser(guy), "pauser not set");
        vm.prank(guy);
        vm.expectRevert(BunniHub__Unauthorized.selector);
        hub.setPauseFlags(pauseFlags);
    }

    function test_vaultTakeLess_duringSwap() public {
        // deploy pool
        (, PoolKey memory key) = _deployPoolAndInitLiquidity(
            Currency.wrap(address(token0)), Currency.wrap(address(token1)), vault0TakeLess, ERC4626(address(0))
        );
        (uint256 beforeBalance0,) = hub.poolBalances(key.toId());

        // swap a lot of token0 into the pool
        uint256 swapAmount = 10 ether;
        _mint(key.currency0, address(this), swapAmount);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        _swap(key, params, 0, "");

        assertEq(token0.balanceOf(address(hub)), 0, "hub should have no token0 ERC20 balance");
        assertEq(token0.allowance(address(hub), address(vault0TakeLess)), 0, "hub should have no allowance to vault");
        (uint256 afterBalance0,) = hub.poolBalances(key.toId());
        assertEq(afterBalance0 - beforeBalance0, swapAmount, "pool balance change incorrect");
    }

    function test_vaultTakeLess_duringDeposit() public {
        // deploy pool
        (, PoolKey memory key) = _deployPoolAndInitLiquidity(
            Currency.wrap(address(token0)), Currency.wrap(address(token1)), vault0TakeLess, ERC4626(address(0))
        );
        (uint256 beforeBalance0,) = hub.poolBalances(key.toId());

        // deposit
        uint256 depositAmount = 10 ether;
        _mint(key.currency0, address(this), depositAmount * 10);
        _mint(key.currency1, address(this), depositAmount * 10);
        uint256 beforeThisBalance0 = token0.balanceOf(address(this));
        IBunniHub.DepositParams memory depositParams = IBunniHub.DepositParams({
            poolKey: key,
            amount0Desired: depositAmount,
            amount1Desired: depositAmount * 10,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp,
            recipient: address(this),
            refundRecipient: address(this),
            vaultFee0: 0.5e18, // since vault only takes half of requested amount we need to effectively use 2x the tokens
            vaultFee1: 0
        });
        hub.deposit(depositParams);

        assertEq(token0.balanceOf(address(hub)), 0, "hub should have no token0 ERC20 balance");
        assertEq(token0.allowance(address(hub), address(vault0TakeLess)), 0, "hub should have no allowance to vault");
        (uint256 afterBalance0,) = hub.poolBalances(key.toId());
        assertEq(afterBalance0 - beforeBalance0, depositAmount, "pool balance change incorrect");
        assertEq(beforeThisBalance0 - token0.balanceOf(address(this)), depositAmount, "user deposited amount incorrect");
    }

    function test_queueWithdrawPoC1() public {
        uint256 depositAmount0 = 1 ether;
        uint256 depositAmount1 = 1 ether;
        (IBunniToken bunniToken, PoolKey memory key) = _deployPoolAndInitLiquidity();

        // make deposit
        (uint256 shares,,) = _makeDepositWithFee({
            key_: key,
            depositAmount0: depositAmount0,
            depositAmount1: depositAmount1,
            depositor: address(this),
            vaultFee0: 0,
            vaultFee1: 0,
            snapLabel: ""
        });

        // bid in am-AMM auction
        PoolId id = key.toId();
        bunniToken.approve(address(bunniHook), type(uint256).max);
        uint128 minRent = uint128(bunniToken.totalSupply() * MIN_RENT_MULTIPLIER / 1e18);
        uint128 rentDeposit = minRent * 2 days;
        bunniHook.bid(id, address(this), bytes6(abi.encodePacked(uint24(1e3), uint24(2e3))), minRent * 2, rentDeposit);
        shares -= rentDeposit;

        // wait until address(this) is the manager
        skipBlocks(K);
        assertEq(bunniHook.getBid(id, true).manager, address(this), "not manager yet");

        vm.warp(type(uint56).max - 1 minutes);

        // queue withdraw
        bunniToken.approve(address(hub), type(uint256).max);
        hub.queueWithdraw(IBunniHub.QueueWithdrawParams({poolKey: key, shares: shares.toUint200()}));
        assertEqDecimal(bunniToken.balanceOf(address(hub)), shares, DECIMALS, "didn't take shares");

        // wait 1 minute
        skip(1 minutes);

        // withdraw
        IBunniHub.WithdrawParams memory withdrawParams = IBunniHub.WithdrawParams({
            poolKey: key,
            recipient: address(this),
            shares: shares,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp,
            useQueuedWithdrawal: true
        });
        // should revert due to unlockTimestamp + WITHDRAW_GRACE_PERIOD overflowing uint56
        // user just needs to requeue
        vm.expectRevert(BunniHub__GracePeriodExpired.selector);
        hub.withdraw(withdrawParams);

        // requeue
        hub.queueWithdraw(IBunniHub.QueueWithdrawParams({poolKey: key, shares: shares.toUint200()}));

        // wait 1 minute
        skip(1 minutes);

        // withdraw
        hub.withdraw(
            IBunniHub.WithdrawParams({
                poolKey: key,
                recipient: address(this),
                shares: shares,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                useQueuedWithdrawal: true
            })
        );
    }

    function test_queueWithdrawPoC2() public {
        uint256 depositAmount0 = 1 ether;
        uint256 depositAmount1 = 1 ether;
        (IBunniToken bunniToken, PoolKey memory key) = _deployPoolAndInitLiquidity();

        // make deposit
        (uint256 shares,,) = _makeDepositWithFee({
            key_: key,
            depositAmount0: depositAmount0,
            depositAmount1: depositAmount1,
            depositor: address(this),
            vaultFee0: 0,
            vaultFee1: 0,
            snapLabel: ""
        });

        // bid in am-AMM auction
        PoolId id = key.toId();
        bunniToken.approve(address(bunniHook), type(uint256).max);
        uint128 minRent = uint128(bunniToken.totalSupply() * MIN_RENT_MULTIPLIER / 1e18);
        uint128 rentDeposit = minRent * 2 days;
        bunniHook.bid(id, address(this), bytes6(abi.encodePacked(uint24(1e3), uint24(2e3))), minRent * 2, rentDeposit);
        shares -= rentDeposit;

        // wait until address(this) is the manager
        skipBlocks(K);
        assertEq(bunniHook.getBid(id, true).manager, address(this), "not manager yet");

        vm.warp(type(uint56).max);

        // queue withdraw
        bunniToken.approve(address(hub), type(uint256).max);
        hub.queueWithdraw(IBunniHub.QueueWithdrawParams({poolKey: key, shares: shares.toUint200()}));
        assertEqDecimal(bunniToken.balanceOf(address(hub)), shares, DECIMALS, "didn't take shares");

        // wait 1 minute
        skip(1 minutes);

        // re-queue before expiry
        // should revert
        vm.expectRevert(BunniHub__NoExpiredWithdrawal.selector);
        hub.queueWithdraw(IBunniHub.QueueWithdrawParams({poolKey: key, shares: shares.toUint200()}));
    }

    function test_WrongIdleBalanceComputation() public {
        ILiquidityDensityFunction uniformDistribution =
            new UniformDistribution(address(hub), address(bunniHook), address(quoter));
        Currency currency0 = Currency.wrap(address(token0));
        Currency currency1 = Currency.wrap(address(token1));
        ERC4626FeeMock feeVault0 = new ERC4626FeeMock(token0, 0);
        ERC4626 vault0_ = ERC4626(address(feeVault0));
        ERC4626 vault1_ = ERC4626(address(0));
        IBunniToken bunniToken;
        PoolKey memory key;
        (bunniToken, key) = hub.deployBunniToken(
            IBunniHub.DeployBunniTokenParams({
                currency0: currency0,
                currency1: currency1,
                tickSpacing: TICK_SPACING,
                twapSecondsAgo: TWAP_SECONDS_AGO,
                liquidityDensityFunction: uniformDistribution,
                hooklet: IHooklet(address(0)),
                ldfType: LDFType.STATIC,
                ldfParams: bytes32(abi.encodePacked(ShiftMode.STATIC, int24(-5) * TICK_SPACING, int24(5) * TICK_SPACING)),
                hooks: bunniHook,
                hookParams: abi.encodePacked(
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
                ),
                vault0: vault0_,
                vault1: vault1_,
                minRawTokenRatio0: 0.2e6,
                targetRawTokenRatio0: 0.3e6,
                maxRawTokenRatio0: 0.4e6,
                minRawTokenRatio1: 0,
                targetRawTokenRatio1: 0,
                maxRawTokenRatio1: 0,
                sqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
                name: bytes32("BunniToken"),
                symbol: bytes32("BUNNI-LP"),
                owner: address(this),
                metadataURI: "metadataURI",
                salt: bytes32(0)
            })
        );

        // make initial deposit to avoid accounting for MIN_INITIAL_SHARES
        uint256 depositAmount0 = 1e18 + 1;
        uint256 depositAmount1 = 1e18 + 1;
        address firstDepositor = makeAddr("firstDepositor");
        vm.startPrank(firstDepositor);
        token0.approve(address(PERMIT2), type(uint256).max);
        token1.approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(address(token0), address(hub), type(uint160).max, type(uint48).max);
        PERMIT2.approve(address(token1), address(hub), type(uint160).max, type(uint48).max);
        vm.stopPrank();

        // mint tokens
        _mint(key.currency0, firstDepositor, depositAmount0 * 100);
        _mint(key.currency1, firstDepositor, depositAmount1 * 100);

        // deposit tokens
        IBunniHub.DepositParams memory depositParams = IBunniHub.DepositParams({
            poolKey: key,
            amount0Desired: depositAmount0,
            amount1Desired: depositAmount1,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp,
            recipient: firstDepositor,
            refundRecipient: firstDepositor,
            vaultFee0: 0,
            vaultFee1: 0
        });

        vm.startPrank(firstDepositor);
        (uint256 sharesFirstDepositor, uint256 firstDepositorAmount0In, uint256 firstDepositorAmount1In) =
            hub.deposit(depositParams);
        console.log("Amount 0 deposited by first depositor", firstDepositorAmount0In);
        console.log("Amount 1 deposited by first depositor", firstDepositorAmount1In);
        console.log("Total supply shares", bunniToken.totalSupply());
        vm.stopPrank();

        IdleBalance idleBalanceBefore = hub.idleBalance(key.toId());
        (uint256 idleAmountBefore, bool isToken0Before) = IdleBalanceLibrary.fromIdleBalance(idleBalanceBefore);
        feeVault0.setFee(1000); // 10% fee

        depositAmount0 = 1e18;
        depositAmount1 = 1e18;
        address secondDepositor = makeAddr("secondDepositor");
        vm.startPrank(secondDepositor);
        token0.approve(address(PERMIT2), type(uint256).max);
        token1.approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(address(token0), address(hub), type(uint160).max, type(uint48).max);
        PERMIT2.approve(address(token1), address(hub), type(uint160).max, type(uint48).max);
        vm.stopPrank();

        // mint tokens
        _mint(key.currency0, secondDepositor, depositAmount0);
        _mint(key.currency1, secondDepositor, depositAmount1);

        // deposit tokens
        depositParams = IBunniHub.DepositParams({
            poolKey: key,
            amount0Desired: depositAmount0,
            amount1Desired: depositAmount1,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp,
            recipient: secondDepositor,
            refundRecipient: secondDepositor,
            vaultFee0: 0,
            vaultFee1: 0
        });

        vm.startPrank(secondDepositor);
        vm.expectRevert(BunniHub__VaultFeeIncorrect.selector);
        (uint256 sharesSecondDepositor, uint256 secondDepositorAmount0In, uint256 secondDepositorAmount1In) =
            hub.deposit(depositParams);
        vm.stopPrank();
    }

    function test_hookWhitelist_authChecks(IBunniHook hook) external {
        // owner can set hook whitelist
        hub.setHookWhitelist(hook, true);
        assertTrue(hub.hookIsWhitelisted(hook), "hook not whitelisted by owner");
        hub.setHookWhitelist(hook, false); // reset
        assertFalse(hub.hookIsWhitelisted(hook), "hook not blacklisted by owner");

        // others cannot set hook whitelist
        address others = makeAddr("others");
        vm.prank(others);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hub.setHookWhitelist(hook, true);
    }

    function test_hookWhitelist_cannotDeployPoolWithBlacklistedHook() external {
        // deploy pool
        (IBunniToken bunniToken, PoolKey memory key) = _deployPoolAndInitLiquidity();

        // blacklist hook
        hub.setHookWhitelist(bunniHook, false);

        // cannot deploy pool
        vm.expectRevert(BunniHub__HookNotWhitelisted.selector);
        hub.deployBunniToken(
            IBunniHub.DeployBunniTokenParams({
                currency0: key.currency0,
                currency1: key.currency1,
                tickSpacing: TICK_SPACING,
                twapSecondsAgo: 7 days,
                liquidityDensityFunction: ldf,
                hooklet: IHooklet(address(0)),
                ldfType: LDFType.DYNAMIC_AND_STATEFUL,
                ldfParams: bytes32(0),
                hooks: bunniHook,
                hookParams: bytes(""),
                vault0: ERC4626(address(0)),
                vault1: ERC4626(address(0)),
                minRawTokenRatio0: 0.08e6,
                targetRawTokenRatio0: 0.1e6,
                maxRawTokenRatio0: 0.12e6,
                minRawTokenRatio1: 0.08e6,
                targetRawTokenRatio1: 0.1e6,
                maxRawTokenRatio1: 0.12e6,
                sqrtPriceX96: uint160(Q96),
                name: "BunniToken",
                symbol: "BUNNI-LP",
                owner: address(this),
                metadataURI: "metadataURI",
                salt: bytes32(0)
            })
        );
    }

    function test_revert_BunniHubDrainingRawBalances() public {
        // 1. Create the malicious pool linked to the malicious hook
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

        // 2. Create the malicious vault
        MaliciousERC4626 maliciousVault = new MaliciousERC4626(token1, customHook);
        token1.approve(address(maliciousVault), type(uint256).max);
        _mint(Currency.wrap(address(token1)), address(maliciousVault), 1 ether);

        // 3. Register the malicious pool
        // we whitelist the pool to show that this attack is impossible even with a whitelisted pool
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
                vault0: ERC4626(address(vault0)),
                vault1: ERC4626(address(maliciousVault)),
                minRawTokenRatio0: 1e6, // set to 100% in order to have all funds in raw balance
                targetRawTokenRatio0: 1e6, // set to 100% in order to have all funds in raw balance
                maxRawTokenRatio0: 1e6, // set to 100% in order to have all funds in raw balance
                minRawTokenRatio1: 0, // set to 0% in order to trigger a deposit upon transfering 1 token
                targetRawTokenRatio1: 0, // set to 0% in order to trigger a deposit upon transfering 1 token
                maxRawTokenRatio1: 0, // set to 0% in order to trigger a deposit upon transfering 1 token
                sqrtPriceX96: TickMath.getSqrtPriceAtTick(4),
                name: bytes32("MaliciousBunniToken"),
                symbol: bytes32("BAD-BUNNI-LP"),
                owner: address(this),
                metadataURI: "metadataURI",
                salt: bytes32(keccak256("malicious"))
            })
        );

        // 4. Add some token0 ERC6909 into the hub to simulate raw balances from other legit pools
        uint256 bunniHubToken0RawBalance = 10 ether;
        poolManager.unlock(abi.encode(address(hub), bunniHubToken0RawBalance, address(token0)));

        // 5. Make a deposit to the malicious pool to have accounted some reserves of vault0 and initiate attack
        uint256 initialToken0Deposit = 1 ether;
        deal(address(token0), address(this), initialToken0Deposit);
        deal(address(token1), address(this), initialToken0Deposit);
        token0.approve(customHook, initialToken0Deposit);
        token1.approve(customHook, initialToken0Deposit);
        CustomHook(payable(customHook)).depositInitialReserves(
            address(token0), initialToken0Deposit, address(hub), poolManager, maliciousKey, true
        );
        CustomHook(payable(customHook)).mintERC6909(address(token1), initialToken0Deposit);
        console.log(
            "Initial hub token0 raw balances",
            poolManager.balanceOf(address(hub), Currency.wrap(address(token0)).toId())
        );

        maliciousVault.setupAttack();
        vm.expectRevert(ReentrancyGuard.ReentrancyGuard__ReentrantCall.selector);
        CustomHook(payable(customHook)).initiateAttack(IBunniHub(address(hub)), maliciousKey, initialToken0Deposit, 10);
        console.log(
            "Final hook token0 raw balance", poolManager.balanceOf(customHook, Currency.wrap(address(token0)).toId())
        );
        console.log(
            "Final hub token0 raw balance", poolManager.balanceOf(address(hub), Currency.wrap(address(token0)).toId())
        );
    }

    function test_revert_BunniHubDrainingVaultReserves() public {
        // 1. Create the malicious pool linked to the malicious hook
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

        // 2. Create the malicious vault
        MaliciousERC4626 maliciousVault = new MaliciousERC4626(token1, customHook);
        token1.approve(address(maliciousVault), type(uint256).max);
        _mint(Currency.wrap(address(token1)), address(maliciousVault), 1 ether);

        // 3. Register the malicious pool
        // we whitelist the pool to show that this attack is impossible even with a whitelisted pool
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
                vault0: ERC4626(address(vault0)), // targeted vault to be drained
                vault1: ERC4626(address(maliciousVault)),
                minRawTokenRatio0: 0, // set to 0% in order to have all deposited funds accounted into the vault
                targetRawTokenRatio0: 0, // set to 0% in order to have all deposited funds accounted into the vault
                maxRawTokenRatio0: 0, // set to 0% in order to have all deposited funds accounted into the vault
                minRawTokenRatio1: 0, // set to 0% in order to trigger a deposit upon transfering 1 token
                targetRawTokenRatio1: 0, // set to 0% in order to trigger a deposit upon transfering 1 token
                maxRawTokenRatio1: 0, // set to 0% in order to trigger a deposit upon transfering 1 token
                sqrtPriceX96: TickMath.getSqrtPriceAtTick(4),
                name: bytes32("MaliciousBunniToken"),
                symbol: bytes32("BAD-BUNNI-LP"),
                owner: address(this),
                metadataURI: "metadataURI",
                salt: bytes32(keccak256("malicious"))
            })
        );

        // 4. Add some token0 reserves into the hub to simulate balances from other legit pools
        uint256 bunniHubToken0Reserves = 10 ether;
        deal(address(token0), address(hub), bunniHubToken0Reserves);
        vm.startPrank(address(hub));
        token0.approve(address(vault0), bunniHubToken0Reserves);
        vault0.deposit(bunniHubToken0Reserves, address(hub));
        vm.stopPrank();

        // 5. Make a deposit to the malicious pool to have accounted some reserves of vault0 and initiate attack
        uint256 initialToken0Deposit = 1 ether;
        deal(address(token0), address(this), initialToken0Deposit);
        deal(address(token1), address(this), initialToken0Deposit);
        token0.approve(customHook, initialToken0Deposit);
        token1.approve(customHook, initialToken0Deposit);
        CustomHook(payable(customHook)).depositInitialReserves(
            address(token0), initialToken0Deposit, address(hub), poolManager, maliciousKey, true
        );
        CustomHook(payable(customHook)).mintERC6909(address(token1), initialToken0Deposit);
        console.log("Initial hub token0 reserve", vault0.balanceOf(address(hub)));

        maliciousVault.setupAttack();
        vm.expectRevert();
        CustomHook(payable(customHook)).initiateAttack(IBunniHub(address(hub)), maliciousKey, initialToken0Deposit, 10);
        console.log(
            "Final hook token0 balance", poolManager.balanceOf(customHook, Currency.wrap(address(token0)).toId())
        );
        console.log("Final hub token0 balance", vault0.balanceOf(address(hub)));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (address hub_, uint256 amount, Currency token) = abi.decode(data, (address, uint256, Currency));

        // call sync on PoolManager
        poolManager.sync(token);

        // mint tokens to PoolManager
        deal(Currency.unwrap(token), address(poolManager), amount);

        // settle balance
        poolManager.settle();

        // mint claim tokens to hub
        poolManager.mint(hub_, token.toId(), amount);

        return bytes("");
    }
}

contract CustomHook {
    uint256 public reentrancyIterations;
    uint256 public iterationsCounter;
    IBunniHub public hub;
    PoolKey public key;
    uint256 public amountOfReservesToWithdraw;
    IPoolManager public poolManager;

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

    function depositInitialReserves(
        address token,
        uint256 amount,
        address _hub,
        IPoolManager _poolManager,
        PoolKey memory _key,
        bool zeroForOne
    ) external {
        key = _key;
        hub = IBunniHub(_hub);
        poolManager = _poolManager;
        poolManager.setOperator(_hub, true);
        poolManager.unlock(abi.encode(uint8(0), token, amount, msg.sender, zeroForOne));
        poolManager.unlock(abi.encode(uint8(1), address(0), amount, msg.sender, zeroForOne));
    }

    function mintERC6909(address token, uint256 amount) external {
        poolManager.unlock(abi.encode(uint8(0), token, amount, msg.sender, true));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory result) {
        (uint8 mode, address token, uint256 amount, address spender, bool zeroForOne) =
            abi.decode(data, (uint8, address, uint256, address, bool));
        if (mode == 0) {
            poolManager.sync(Currency.wrap(token));
            IERC20(token).transferFrom(spender, address(poolManager), amount);
            uint256 deltaAmount = poolManager.settle();
            poolManager.mint(address(this), Currency.wrap(token).toId(), deltaAmount);
        } else if (mode == 1) {
            hub.hookHandleSwap(key, zeroForOne, amount, 0, false);
        } else if (mode == 2) {
            hub.hookHandleSwap(key, false, 1, amountOfReservesToWithdraw, false);
        }
    }

    function initiateAttack(
        IBunniHub _hub,
        PoolKey memory _key,
        uint256 _amountOfReservesToWithdraw,
        uint256 iterations
    ) public {
        reentrancyIterations = iterations;
        iterationsCounter = 0;
        hub = _hub;
        key = _key;
        amountOfReservesToWithdraw = _amountOfReservesToWithdraw;
        poolManager.unlock(abi.encode(uint8(2), address(0), amountOfReservesToWithdraw, msg.sender, true));
    }

    function continueAttackFromMaliciousVault() public {
        if (iterationsCounter != reentrancyIterations) {
            iterationsCounter++;
            disableReentrancyGuard();
            hub.hookHandleSwap(
                key, false, 1, /* amountToDeposit to trigger the updateIfNeeded */ amountOfReservesToWithdraw, false
            );
        }
    }

    function disableReentrancyGuard() public {
        // Note: commented out because unlockForRebalance() no longer exists in BunniHub
        // hub.unlockForRebalance(key);
    }

    fallback() external payable {}
}
