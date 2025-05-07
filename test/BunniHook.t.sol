// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import "./BaseTest.sol";

contract BunniHookTest is BaseTest {
    using TickMath for *;
    using FullMathX96 for *;
    using SafeCastLib for *;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;

    function setUp() public override {
        super.setUp();
    }

    function test_swap_zeroForOne_noTickCrossing() public {
        _execTestAcrossScenarios(
            _test_swap_zeroForOne_noTickCrossing, 0, 0, "swap zeroForOne noTickCrossing, first swap"
        );
    }

    function _test_swap_zeroForOne_noTickCrossing(
        uint256,
        uint256,
        Currency currency0,
        Currency currency1,
        ERC4626 vault0_,
        ERC4626 vault1_,
        string memory snapLabel
    ) internal {
        (, PoolKey memory key) = _deployPoolAndInitLiquidity(currency0, currency1, vault0_, vault1_);

        uint256 inputAmount = PRECISION / 10;

        _mint(key.currency0, address(this), inputAmount);
        uint256 value = key.currency0.isAddressZero() ? inputAmount : 0;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(inputAmount),
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(3)
        });
        _swap(key, params, value, snapLabel);
    }

    function test_swap_zeroForOne_noTickCrossing_multiple() public {
        _execTestAcrossScenarios(
            _test_swap_zeroForOne_noTickCrossing_multiple, 0, 0, "swap zeroForOne noTickCrossing, subsequent swap"
        );
    }

    function _test_swap_zeroForOne_noTickCrossing_multiple(
        uint256,
        uint256,
        Currency currency0,
        Currency currency1,
        ERC4626 vault0_,
        ERC4626 vault1_,
        string memory snapLabel
    ) internal {
        (, PoolKey memory key) = _deployPoolAndInitLiquidity(currency0, currency1, vault0_, vault1_);

        uint256 numSwaps = 10;
        uint256 inputAmount = PRECISION / 1000;
        uint256 value = key.currency0.isAddressZero() ? inputAmount : 0;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(inputAmount),
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(0)
        });

        for (uint256 i; i < numSwaps; i++) {
            _mint(key.currency0, address(this), inputAmount);

            if (i == numSwaps - 1) {
                _swap(key, params, value, snapLabel);
            } else {
                _swap(key, params, value, "");
            }
        }
    }

    function test_swap_zeroForOne_oneTickCrossing() public {
        _execTestAcrossScenarios(
            _test_swap_zeroForOne_oneTickCrossing, 0, 0, "swap zeroForOne oneTickCrossing, first swap"
        );
    }

    function _test_swap_zeroForOne_oneTickCrossing(
        uint256,
        uint256,
        Currency currency0,
        Currency currency1,
        ERC4626 vault0_,
        ERC4626 vault1_,
        string memory snapLabel
    ) internal {
        (, PoolKey memory key) = _deployPoolAndInitLiquidity(currency0, currency1, vault0_, vault1_);

        uint256 inputAmount = 0.15e18;
        uint256 value = key.currency0.isAddressZero() ? inputAmount : 0;

        _mint(key.currency0, address(this), inputAmount);

        (, int24 currentTick,,) = bunniHook.slot0s(key.toId());
        int24 beforeRoundedTick = roundTickSingle(currentTick, key.tickSpacing);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(inputAmount),
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(-9)
        });

        _swap(key, params, value, snapLabel);

        (, currentTick,,) = bunniHook.slot0s(key.toId());
        int24 afterRoundedTick = roundTickSingle(currentTick, key.tickSpacing);
        assertEq(afterRoundedTick, beforeRoundedTick - key.tickSpacing, "didn't cross one tick");
    }

    function test_swap_zeroForOne_twoTickCrossing() public {
        _execTestAcrossScenarios(
            _test_swap_zeroForOne_twoTickCrossing, 0, 0, "swap zeroForOne twoTickCrossing, first swap"
        );
    }

    function _test_swap_zeroForOne_twoTickCrossing(
        uint256,
        uint256,
        Currency currency0,
        Currency currency1,
        ERC4626 vault0_,
        ERC4626 vault1_,
        string memory snapLabel
    ) internal {
        (, PoolKey memory key) = _deployPoolAndInitLiquidity(currency0, currency1, vault0_, vault1_);

        uint256 inputAmount = PRECISION * 2;
        uint256 value = key.currency0.isAddressZero() ? inputAmount : 0;

        _mint(key.currency0, address(this), inputAmount);

        (, int24 currentTick,,) = bunniHook.slot0s(key.toId());
        int24 beforeRoundedTick = roundTickSingle(currentTick, key.tickSpacing);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(inputAmount),
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(-19)
        });

        _swap(key, params, value, snapLabel);

        (, currentTick,,) = bunniHook.slot0s(key.toId());
        int24 afterRoundedTick = roundTickSingle(currentTick, key.tickSpacing);
        assertEq(afterRoundedTick, beforeRoundedTick - key.tickSpacing * 2, "didn't cross two ticks");
    }

    function test_swap_zeroForOne_oneTickCrossing_limit() public {
        _execTestAcrossScenarios(
            _test_swap_zeroForOne_oneTickCrossing_limit, 0, 0, "swap zeroForOne oneTickCrossing, first swap, hit limit"
        );
    }

    function _test_swap_zeroForOne_oneTickCrossing_limit(
        uint256,
        uint256,
        Currency currency0,
        Currency currency1,
        ERC4626 vault0_,
        ERC4626 vault1_,
        string memory snapLabel
    ) internal {
        (, PoolKey memory key) = _deployPoolAndInitLiquidity(currency0, currency1, vault0_, vault1_);

        uint256 inputAmount = 5.4e17;
        uint256 value = key.currency0.isAddressZero() ? inputAmount : 0;

        _mint(key.currency0, address(this), inputAmount);

        (, int24 currentTick,,) = bunniHook.slot0s(key.toId());
        int24 beforeRoundedTick = roundTickSingle(currentTick, key.tickSpacing);

        uint160 sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(-9);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(inputAmount),
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        _swap(key, params, value, snapLabel);

        uint160 sqrtPriceX96;
        (sqrtPriceX96, currentTick,,) = bunniHook.slot0s(key.toId());
        int24 afterRoundedTick = roundTickSingle(currentTick, key.tickSpacing);
        assertEq(afterRoundedTick, beforeRoundedTick - key.tickSpacing, "didn't cross one tick");
        assertEq(sqrtPriceX96, sqrtPriceLimitX96, "didn't hit price limit");
    }

    function test_swap_oneForZero_noTickCrossing() public {
        _execTestAcrossScenarios(
            _test_swap_oneForZero_noTickCrossing, 0, 0, "swap oneForZero noTickCrossing, first swap"
        );
    }

    function _test_swap_oneForZero_noTickCrossing(
        uint256,
        uint256,
        Currency currency0,
        Currency currency1,
        ERC4626 vault0_,
        ERC4626 vault1_,
        string memory snapLabel
    ) internal {
        (, PoolKey memory key) = _deployPoolAndInitLiquidity(currency0, currency1, vault0_, vault1_);

        uint256 inputAmount = PRECISION / 10;
        uint256 value = key.currency1.isAddressZero() ? inputAmount : 0;

        _mint(key.currency1, address(this), inputAmount);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(inputAmount),
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(9)
        });

        _swap(key, params, value, snapLabel);
    }

    function test_swap_oneForZero_noTickCrossing_multiple() public {
        _execTestAcrossScenarios(
            _test_swap_oneForZero_noTickCrossing_multiple, 0, 0, "swap oneForZero noTickCrossing, subsequent swap"
        );
    }

    function _test_swap_oneForZero_noTickCrossing_multiple(
        uint256,
        uint256,
        Currency currency0,
        Currency currency1,
        ERC4626 vault0_,
        ERC4626 vault1_,
        string memory snapLabel
    ) internal {
        (, PoolKey memory key) = _deployPoolAndInitLiquidity(currency0, currency1, vault0_, vault1_);

        uint256 numSwaps = 10;
        uint256 inputAmount = PRECISION / 1000;
        uint256 value = key.currency1.isAddressZero() ? inputAmount : 0;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(inputAmount),
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(9)
        });

        for (uint256 i; i < numSwaps; i++) {
            _mint(key.currency1, address(this), inputAmount);

            if (i == numSwaps - 1) {
                _swap(key, params, value, snapLabel);
            } else {
                _swap(key, params, value, "");
            }
        }
    }

    function test_swap_oneForZero_oneTickCrossing() public {
        _execTestAcrossScenarios(
            _test_swap_oneForZero_oneTickCrossing, 0, 0, "swap oneForZero oneTickCrossing, first swap"
        );
    }

    function _test_swap_oneForZero_oneTickCrossing(
        uint256,
        uint256,
        Currency currency0,
        Currency currency1,
        ERC4626 vault0_,
        ERC4626 vault1_,
        string memory snapLabel
    ) internal {
        (, PoolKey memory key) = _deployPoolAndInitLiquidity(currency0, currency1, vault0_, vault1_);

        uint256 inputAmount = PRECISION * 2;
        uint256 value = key.currency1.isAddressZero() ? inputAmount : 0;

        _mint(key.currency1, address(this), inputAmount);

        (, int24 currentTick,,) = bunniHook.slot0s(key.toId());
        int24 beforeRoundedTick = roundTickSingle(currentTick, key.tickSpacing);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(inputAmount),
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(19)
        });

        _swap(key, params, value, snapLabel);

        (, currentTick,,) = bunniHook.slot0s(key.toId());
        int24 afterRoundedTick = roundTickSingle(currentTick, key.tickSpacing);
        assertEq(afterRoundedTick, beforeRoundedTick + key.tickSpacing, "didn't cross one tick");
    }

    function test_swap_oneForZero_twoTickCrossing() public {
        _execTestAcrossScenarios(_test_swap_oneForZero_twoTickCrossing, 0, 0, "swap oneForZero twoTickCrossing");
    }

    function _test_swap_oneForZero_twoTickCrossing(
        uint256,
        uint256,
        Currency currency0,
        Currency currency1,
        ERC4626 vault0_,
        ERC4626 vault1_,
        string memory snapLabel
    ) internal {
        (, PoolKey memory key) = _deployPoolAndInitLiquidity(currency0, currency1, vault0_, vault1_);

        uint256 inputAmount = PRECISION * 2;
        uint256 value = key.currency1.isAddressZero() ? inputAmount : 0;

        _mint(key.currency1, address(this), inputAmount);

        (, int24 currentTick,,) = bunniHook.slot0s(key.toId());
        int24 beforeRoundedTick = roundTickSingle(currentTick, key.tickSpacing);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(inputAmount),
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(29)
        });

        _swap(key, params, value, snapLabel);

        (, currentTick,,) = bunniHook.slot0s(key.toId());
        int24 afterRoundedTick = roundTickSingle(currentTick, key.tickSpacing);
        assertEq(afterRoundedTick, beforeRoundedTick + key.tickSpacing * 2, "didn't cross two ticks");
    }

    function test_swap_oneForZero_oneTickCrossing_limit() public {
        _execTestAcrossScenarios(
            _test_swap_oneForZero_oneTickCrossing_limit, 0, 0, "swap oneForZero oneTickCrossing, first swap, hit limit"
        );
    }

    function _test_swap_oneForZero_oneTickCrossing_limit(
        uint256,
        uint256,
        Currency currency0,
        Currency currency1,
        ERC4626 vault0_,
        ERC4626 vault1_,
        string memory snapLabel
    ) internal {
        (, PoolKey memory key) = _deployPoolAndInitLiquidity(currency0, currency1, vault0_, vault1_);

        uint256 inputAmount = 2.5e17;
        uint256 value = key.currency1.isAddressZero() ? inputAmount : 0;

        _mint(key.currency1, address(this), inputAmount);

        (, int24 currentTick,,) = bunniHook.slot0s(key.toId());
        int24 beforeRoundedTick = roundTickSingle(currentTick, key.tickSpacing);

        uint160 sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(19);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(inputAmount),
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        _swap(key, params, value, snapLabel);

        uint160 sqrtPriceX96;
        (sqrtPriceX96, currentTick,,) = bunniHook.slot0s(key.toId());
        int24 afterRoundedTick = roundTickSingle(currentTick, key.tickSpacing);
        assertEq(afterRoundedTick, beforeRoundedTick + key.tickSpacing, "didn't cross one tick");
        assertEq(sqrtPriceX96, sqrtPriceLimitX96, "didn't hit price limit");
    }

    function test_collectProtocolFees() public {
        _execTestAcrossScenarios(_test_collectProtocolFees, 0, 0, "");
    }

    function _test_collectProtocolFees(
        uint256,
        uint256,
        Currency currency0,
        Currency currency1,
        ERC4626 vault0_,
        ERC4626 vault1_,
        string memory snapLabel
    ) internal {
        // create new bunni token
        (, PoolKey memory key) = _deployPoolAndInitLiquidity(currency0, currency1, vault0_, vault1_);

        uint256 inputAmount = PRECISION * 100;
        IPoolManager.SwapParams memory paramsZeroToOne = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(inputAmount),
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(-9)
        });
        IPoolManager.SwapParams memory paramsOneToZero = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(inputAmount),
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(9)
        });

        // make swaps to accumulate fees
        uint256 numSwaps = 10;
        for (uint256 i; i < numSwaps; i++) {
            // zero to one swap
            _mint(key.currency0, address(this), inputAmount);
            uint256 value = key.currency0.isAddressZero() ? inputAmount : 0;
            if (i == numSwaps - 1) {
                _swap(
                    key,
                    paramsZeroToOne,
                    value,
                    string.concat("swap zeroForOne oneTickCrossing, subsequent swap", snapLabel)
                );
            } else {
                _swap(key, paramsZeroToOne, value, "");
            }

            // one to zero swap
            _mint(key.currency1, address(this), inputAmount);
            value = key.currency1.isAddressZero() ? inputAmount : 0;
            if (i == numSwaps - 1) {
                _swap(
                    key,
                    paramsOneToZero,
                    value,
                    string.concat("swap oneForZero oneTickCrossing, subsequent swap", snapLabel)
                );
            } else {
                _swap(key, paramsOneToZero, value, "");
            }
        }

        uint256 fee0 = poolManager.balanceOf(address(bunniHook), key.currency0.toId());
        uint256 fee1 = poolManager.balanceOf(address(bunniHook), key.currency1.toId());
        assertGt(fee0, 0, "protocol fee0 not accrued");
        assertGt(fee1, 0, "protocol fee1 not accrued");

        // check claimable fees
        Currency[] memory currencies = new Currency[](2);
        currencies[0] = key.currency0;
        currencies[1] = key.currency1;
        uint256[] memory claimableAmounts = bunniHook.getClaimableHookFees(currencies);
        assertEq(claimableAmounts[0], fee0, "claimable fee0 amount incorrect");
        assertEq(claimableAmounts[1], fee1, "claimable fee1 amount incorrect");

        // collect fees
        bunniHook.claimProtocolFees(currencies);
        vm.snapshotGasLastCall(string.concat("collect protocol fees", snapLabel));

        // check balances
        assertEq(
            key.currency0.isAddressZero()
                ? weth.balanceOf(HOOK_FEE_RECIPIENT)
                : key.currency0.balanceOf(HOOK_FEE_RECIPIENT),
            fee0,
            "protocol fee0 not collected"
        );
        assertEq(
            key.currency1.isAddressZero()
                ? weth.balanceOf(HOOK_FEE_RECIPIENT)
                : key.currency1.balanceOf(HOOK_FEE_RECIPIENT),
            fee1,
            "protocol fee1 not collected"
        );
    }

    function test_hookHasInsufficientTokens() external {
        MockLDF ldf_ = new MockLDF(address(hub), address(bunniHook), address(quoter));

        // set mu to be far to the left of rounded tick 0
        // so that the pool will have mostly token1
        ldf_.setMinTick(-100);

        // deploy pool and init liquidity
        Currency currency0 = CurrencyLibrary.ADDRESS_ZERO;
        Currency currency1 = Currency.wrap(address(token0));
        (, PoolKey memory key) =
            _deployPoolAndInitLiquidity(currency0, currency1, ERC4626(address(0)), ERC4626(address(0)), ldf_);

        // set mu to rounded tick 0
        // so that the pool has less token0 than the LDF suggests
        ldf_.setMinTick(0);

        // make a big swap from token1 to token0
        // such that the pool has insufficient tokens to output
        // should revert
        uint256 inputAmount = 100 * PRECISION;
        _mint(key.currency1, address(this), inputAmount);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(inputAmount),
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(100)
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                WrappedError.selector,
                address(bunniHook),
                IHooks.beforeSwap.selector,
                abi.encodePacked(BunniHook__RequestedOutputExceedsBalance.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swapper.swap(key, params, type(uint256).max, 0);
    }

    function test_fuzz_swapNoArb_exactIn(
        uint256 swapAmount,
        bool zeroForOneFirstSwap,
        bool useVault0,
        bool useVault1,
        uint256 waitTime,
        uint32 alpha,
        uint24 feeMin,
        uint24 feeMax,
        uint24 feeQuadraticMultiplier
    ) external {
        swapAmount = bound(swapAmount, 1e6, 1e36);
        waitTime = bound(waitTime, 10, SURGE_AUTOSTART_TIME * 6);
        feeMin = uint24(bound(feeMin, 2e5, 1e6 - 1));
        feeMax = uint24(bound(feeMax, feeMin, 1e6 - 1));
        alpha = uint32(bound(alpha, 1e3, 12e8));

        GeometricDistribution ldf_ = new GeometricDistribution(address(hub), address(bunniHook), address(quoter));
        bytes32 ldfParams = bytes32(abi.encodePacked(ShiftMode.BOTH, int24(-3) * TICK_SPACING, int16(6), alpha));
        {
            PoolKey memory key_;
            key_.tickSpacing = TICK_SPACING;
            vm.assume(ldf_.isValidParams(key_, TWAP_SECONDS_AGO, ldfParams));
        }
        (, PoolKey memory key) = _deployPoolAndInitLiquidity(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            useVault0 ? vault0 : ERC4626(address(0)),
            useVault1 ? vault1 : ERC4626(address(0)),
            ldf_,
            ldfParams,
            abi.encodePacked(
                feeMin,
                feeMax,
                feeQuadraticMultiplier,
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

        // execute first swap
        (Currency firstSwapInputToken, Currency firstSwapOutputToken) =
            zeroForOneFirstSwap ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        _mint(firstSwapInputToken, address(this), swapAmount * 2);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOneFirstSwap,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: zeroForOneFirstSwap ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        uint256 firstSwapInputAmount;
        uint256 firstSwapOutputAmount;
        {
            uint256 beforeInputTokenBalance = firstSwapInputToken.balanceOfSelf();
            uint256 beforeOutputTokenBalance = firstSwapOutputToken.balanceOfSelf();
            _swap(key, params, 0, "");
            firstSwapInputAmount = beforeInputTokenBalance - firstSwapInputToken.balanceOfSelf();
            firstSwapOutputAmount = firstSwapOutputToken.balanceOfSelf() - beforeOutputTokenBalance;
        }

        console2.log("firstSwapInputAmount", firstSwapInputAmount);
        console2.log("firstSwapOutputAmount", firstSwapOutputAmount);

        // wait for some time
        skip(waitTime);

        // execute second swap
        params = IPoolManager.SwapParams({
            zeroForOne: !zeroForOneFirstSwap,
            amountSpecified: -int256(firstSwapOutputAmount),
            sqrtPriceLimitX96: !zeroForOneFirstSwap ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        uint256 secondSwapInputAmount;
        uint256 secondSwapOutputAmount;
        {
            uint256 beforeInputTokenBalance = firstSwapOutputToken.balanceOfSelf();
            uint256 beforeOutputTokenBalance = firstSwapInputToken.balanceOfSelf();
            _swap(key, params, 0, "");
            secondSwapInputAmount = beforeInputTokenBalance - firstSwapOutputToken.balanceOfSelf();
            secondSwapOutputAmount = firstSwapInputToken.balanceOfSelf() - beforeOutputTokenBalance;
        }

        console2.log("secondSwapInputAmount", secondSwapInputAmount);
        console2.log("secondSwapOutputAmount", secondSwapOutputAmount);

        // verify no profits
        assertLeDecimal(secondSwapOutputAmount, firstSwapInputAmount, 18, "arb has profit");
    }

    function test_fuzz_swapNoArb_exactOut(
        uint256 swapAmount,
        bool zeroForOneFirstSwap,
        bool useVault0,
        bool useVault1,
        uint256 waitTime,
        uint32 alpha,
        uint24 feeMin,
        uint24 feeMax,
        uint24 feeQuadraticMultiplier
    ) external {
        swapAmount = bound(swapAmount, 1e6, 1e30);
        waitTime = bound(waitTime, 10, SURGE_AUTOSTART_TIME * 6);
        feeMin = uint24(bound(feeMin, 2e5, 1e6 - 1));
        feeMax = uint24(bound(feeMax, feeMin, 1e6 - 1));
        alpha = uint32(bound(alpha, 1e3, 12e8));

        GeometricDistribution ldf_ = new GeometricDistribution(address(hub), address(bunniHook), address(quoter));
        bytes32 ldfParams = bytes32(abi.encodePacked(ShiftMode.BOTH, int24(-3) * TICK_SPACING, int16(6), alpha));
        {
            PoolKey memory key_;
            key_.tickSpacing = TICK_SPACING;
            vm.assume(ldf_.isValidParams(key_, TWAP_SECONDS_AGO, ldfParams));
        }
        (, PoolKey memory key) = _deployPoolAndInitLiquidity(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            useVault0 ? vault0 : ERC4626(address(0)),
            useVault1 ? vault1 : ERC4626(address(0)),
            swapAmount * 100,
            swapAmount * 100,
            ldf_,
            ldfParams,
            abi.encodePacked(
                feeMin,
                feeMax,
                feeQuadraticMultiplier,
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

        // execute first swap
        (Currency firstSwapInputToken, Currency firstSwapOutputToken) =
            zeroForOneFirstSwap ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOneFirstSwap,
            amountSpecified: int256(swapAmount),
            sqrtPriceLimitX96: zeroForOneFirstSwap ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        (,,, uint256 firstSwapInputAmount, uint256 firstSwapOutputAmount,,) =
            quoter.quoteSwap(address(this), key, params);
        if (firstSwapOutputToken.balanceOf(address(poolManager)) >= swapAmount) {
            assertApproxEqAbs(firstSwapOutputAmount, swapAmount, 10, "firstSwapOutputAmount incorrect");
        }
        _mint(firstSwapInputToken, address(this), firstSwapInputAmount);
        {
            uint256 beforeInputTokenBalance = firstSwapInputToken.balanceOfSelf();
            uint256 beforeOutputTokenBalance = firstSwapOutputToken.balanceOfSelf();
            _swap(key, params, 0, "");
            firstSwapInputAmount = beforeInputTokenBalance - firstSwapInputToken.balanceOfSelf();
            firstSwapOutputAmount = firstSwapOutputToken.balanceOfSelf() - beforeOutputTokenBalance;
        }

        console2.log("firstSwapInputAmount", firstSwapInputAmount);
        console2.log("firstSwapOutputAmount", firstSwapOutputAmount);

        // wait for some time
        skip(waitTime);

        // execute second swap
        params = IPoolManager.SwapParams({
            zeroForOne: !zeroForOneFirstSwap,
            amountSpecified: -int256(firstSwapOutputAmount),
            sqrtPriceLimitX96: !zeroForOneFirstSwap ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        uint256 secondSwapInputAmount;
        uint256 secondSwapOutputAmount;
        {
            uint256 beforeInputTokenBalance = firstSwapOutputToken.balanceOfSelf();
            uint256 beforeOutputTokenBalance = firstSwapInputToken.balanceOfSelf();
            _swap(key, params, 0, "");
            secondSwapInputAmount = beforeInputTokenBalance - firstSwapOutputToken.balanceOfSelf();
            secondSwapOutputAmount = firstSwapInputToken.balanceOfSelf() - beforeOutputTokenBalance;
        }

        console2.log("secondSwapInputAmount", secondSwapInputAmount);
        console2.log("secondSwapOutputAmount", secondSwapOutputAmount);

        // verify no profits
        assertLeDecimal(secondSwapOutputAmount, firstSwapInputAmount, 18, "arb has profit");
    }

    function test_fuzz_swapNoArb_double(
        uint256 swapAmount,
        bool zeroForOneFirstSwap,
        bool useVault0,
        bool useVault1,
        uint256 waitTime,
        uint32 alpha,
        uint24 feeMin,
        uint24 feeMax,
        uint24 feeQuadraticMultiplier
    ) external {
        swapAmount = bound(swapAmount, 1e6, 1e33);
        waitTime = bound(waitTime, 10, SURGE_AUTOSTART_TIME * 3);
        feeMin = uint24(bound(feeMin, 0, 1e6 - 1));
        feeMax = uint24(bound(feeMax, feeMin, 1e6 - 1));
        alpha = uint32(bound(alpha, 1e3, 12e8));

        GeometricDistribution ldf_ = new GeometricDistribution(address(hub), address(bunniHook), address(quoter));
        bytes32 ldfParams = bytes32(abi.encodePacked(ShiftMode.BOTH, int24(-3) * TICK_SPACING, int16(6), alpha));
        {
            PoolKey memory key_;
            key_.tickSpacing = TICK_SPACING;
            vm.assume(ldf_.isValidParams(key_, TWAP_SECONDS_AGO, ldfParams));
        }
        (, PoolKey memory key) = _deployPoolAndInitLiquidity(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            useVault0 ? vault0 : ERC4626(address(0)),
            useVault1 ? vault1 : ERC4626(address(0)),
            ldf_,
            ldfParams,
            abi.encodePacked(
                feeMin,
                feeMax,
                feeQuadraticMultiplier,
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

        // execute first swap
        (Currency firstSwapInputToken, Currency firstSwapOutputToken) =
            zeroForOneFirstSwap ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        _mint(firstSwapInputToken, address(this), swapAmount * 2);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOneFirstSwap,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: zeroForOneFirstSwap ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        uint256 firstSwapInputAmount;
        uint256 firstSwapOutputAmount;
        {
            uint256 beforeInputTokenBalance = firstSwapInputToken.balanceOfSelf();
            uint256 beforeOutputTokenBalance = firstSwapOutputToken.balanceOfSelf();
            bool success = _trySwap(key, params, 0, "");
            vm.assume(success);
            firstSwapInputAmount = beforeInputTokenBalance - firstSwapInputToken.balanceOfSelf();
            firstSwapOutputAmount = firstSwapOutputToken.balanceOfSelf() - beforeOutputTokenBalance;
        }

        console2.log("firstSwapInputAmount", firstSwapInputAmount);
        console2.log("firstSwapOutputAmount", firstSwapOutputAmount);

        // wait for some time
        skip(waitTime);

        // execute second swap
        vm.assume(firstSwapOutputAmount != 0);
        params = IPoolManager.SwapParams({
            zeroForOne: !zeroForOneFirstSwap,
            amountSpecified: -int256(firstSwapOutputAmount),
            sqrtPriceLimitX96: !zeroForOneFirstSwap ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        uint256 secondSwapInputAmount;
        uint256 secondSwapOutputAmount;
        {
            uint256 beforeInputTokenBalance = firstSwapOutputToken.balanceOfSelf();
            uint256 beforeOutputTokenBalance = firstSwapInputToken.balanceOfSelf();
            bool success = _trySwap(key, params, 0, "");
            vm.assume(success);
            secondSwapInputAmount = beforeInputTokenBalance - firstSwapOutputToken.balanceOfSelf();
            secondSwapOutputAmount = firstSwapInputToken.balanceOfSelf() - beforeOutputTokenBalance;
        }

        console2.log("secondSwapInputAmount", secondSwapInputAmount);
        console2.log("secondSwapOutputAmount", secondSwapOutputAmount);

        // wait for some time
        skip(waitTime);

        // execute third swap
        vm.assume(secondSwapOutputAmount != 0);
        params = IPoolManager.SwapParams({
            zeroForOne: zeroForOneFirstSwap,
            amountSpecified: -int256(secondSwapOutputAmount),
            sqrtPriceLimitX96: zeroForOneFirstSwap ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        uint256 thirdSwapInputAmount;
        uint256 thirdSwapOutputAmount;
        {
            uint256 beforeInputTokenBalance = firstSwapInputToken.balanceOfSelf();
            uint256 beforeOutputTokenBalance = firstSwapOutputToken.balanceOfSelf();
            bool success = _trySwap(key, params, 0, "");
            vm.assume(success);
            thirdSwapInputAmount = beforeInputTokenBalance - firstSwapInputToken.balanceOfSelf();
            thirdSwapOutputAmount = firstSwapOutputToken.balanceOfSelf() - beforeOutputTokenBalance;
        }

        console2.log("thirdSwapInputAmount", thirdSwapInputAmount);
        console2.log("thirdSwapOutputAmount", thirdSwapOutputAmount);

        // wait for some time
        skip(waitTime);

        // execute fourth swap
        vm.assume(thirdSwapOutputAmount != 0);
        params = IPoolManager.SwapParams({
            zeroForOne: !zeroForOneFirstSwap,
            amountSpecified: -int256(thirdSwapOutputAmount),
            sqrtPriceLimitX96: !zeroForOneFirstSwap ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        uint256 fourthSwapInputAmount;
        uint256 fourthSwapOutputAmount;
        {
            uint256 beforeInputTokenBalance = firstSwapOutputToken.balanceOfSelf();
            uint256 beforeOutputTokenBalance = firstSwapInputToken.balanceOfSelf();
            bool success = _trySwap(key, params, 0, "");
            vm.assume(success);
            fourthSwapInputAmount = beforeInputTokenBalance - firstSwapOutputToken.balanceOfSelf();
            fourthSwapOutputAmount = firstSwapInputToken.balanceOfSelf() - beforeOutputTokenBalance;
        }

        console2.log("fourthSwapInputAmount", fourthSwapInputAmount);
        console2.log("fourthSwapOutputAmount", fourthSwapOutputAmount);

        // verify no profits
        assertLeDecimal(
            secondSwapOutputAmount + fourthSwapOutputAmount,
            firstSwapInputAmount + thirdSwapInputAmount,
            18,
            "arb has profit"
        );
    }

    function test_fuzz_quoter_quoteSwap(
        uint256 swapAmount,
        bool zeroForOne,
        bool useVault0,
        bool useVault1,
        uint32 alpha,
        uint24 feeMin,
        uint24 feeMax,
        uint24 feeQuadraticMultiplier,
        bool amAmmEnabled
    ) external {
        swapAmount = bound(swapAmount, 1e6, 1e36);
        feeMin = uint24(bound(feeMin, 2e5, 1e6 - 1));
        feeMax = uint24(bound(feeMax, feeMin, 1e6 - 1));
        alpha = uint32(bound(alpha, 1e3, 12e8));

        GeometricDistribution ldf_ = new GeometricDistribution(address(hub), address(bunniHook), address(quoter));
        bytes32 ldfParams = bytes32(abi.encodePacked(ShiftMode.BOTH, int24(-3) * TICK_SPACING, int16(6), alpha));
        {
            PoolKey memory key_;
            key_.tickSpacing = TICK_SPACING;
            vm.assume(ldf_.isValidParams(key_, TWAP_SECONDS_AGO, ldfParams));
        }
        (, PoolKey memory key) = _deployPoolAndInitLiquidity(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            useVault0 ? vault0 : ERC4626(address(0)),
            useVault1 ? vault1 : ERC4626(address(0)),
            ldf_,
            ldfParams,
            abi.encodePacked(
                feeMin,
                feeMax,
                feeQuadraticMultiplier,
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
                amAmmEnabled,
                ORACLE_MIN_INTERVAL,
                MIN_RENT_MULTIPLIER
            )
        );

        (Currency inputToken, Currency outputToken) =
            zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        _mint(inputToken, address(this), swapAmount * 2);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        // quote swap
        (bool success,,, uint256 inputAmount, uint256 outputAmount,,) = quoter.quoteSwap(address(this), key, params);
        assertTrue(success, "quoteSwap failed");

        // execute swap
        uint256 actualInputAmount;
        uint256 actualOutputAmount;
        {
            uint256 beforeInputTokenBalance = inputToken.balanceOfSelf();
            uint256 beforeOutputTokenBalance = outputToken.balanceOfSelf();
            swapper.swap(key, params, type(uint256).max, 0);
            actualInputAmount = beforeInputTokenBalance - inputToken.balanceOfSelf();
            actualOutputAmount = outputToken.balanceOfSelf() - beforeOutputTokenBalance;
        }

        // check if actual amounts match quoted amounts
        assertEq(actualInputAmount, inputAmount, "actual input amount doesn't match quoted input amount");
        assertEq(actualOutputAmount, outputAmount, "actual output amount doesn't match quoted output amount");
    }

    function test_fuzz_quoter_quoteDeposit(
        uint256 depositAmount0,
        uint256 depositAmount1,
        bool useVault0,
        bool useVault1,
        uint32 alpha,
        uint24 feeMin,
        uint24 feeMax,
        uint24 feeQuadraticMultiplier
    ) external {
        depositAmount0 = bound(depositAmount0, 1e9, 1e36);
        depositAmount1 = bound(depositAmount1, 1e9, 1e36);
        feeMin = uint24(bound(feeMin, 2e5, 1e6 - 1));
        feeMax = uint24(bound(feeMax, feeMin, 1e6 - 1));
        alpha = uint32(bound(alpha, 1e3, 12e8));

        GeometricDistribution ldf_ = new GeometricDistribution(address(hub), address(bunniHook), address(quoter));
        bytes32 ldfParams = bytes32(abi.encodePacked(ShiftMode.BOTH, int24(-3) * TICK_SPACING, int16(6), alpha));
        {
            PoolKey memory key_;
            key_.tickSpacing = TICK_SPACING;
            vm.assume(ldf_.isValidParams(key_, TWAP_SECONDS_AGO, ldfParams));
        }
        (, PoolKey memory key) = _deployPoolAndInitLiquidity(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            useVault0 ? vault0 : ERC4626(address(0)),
            useVault1 ? vault1 : ERC4626(address(0)),
            ldf_,
            ldfParams,
            abi.encodePacked(
                feeMin,
                feeMax,
                feeQuadraticMultiplier,
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

        // quote deposit
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
            vaultFee1: 0,
            referrer: address(0)
        });
        (bool success, uint256 shares, uint256 amount0, uint256 amount1) =
            quoter.quoteDeposit(address(this), depositParams);
        assertTrue(success, "quoteDeposit failed");

        // deposit tokens
        (uint256 actualShares, uint256 actualAmount0, uint256 actualAmount1) =
            _makeDeposit(key, depositAmount0, depositAmount1, address(this), "");

        // check if actual amounts match quoted amounts
        assertApproxEqRel(actualShares, shares, 1e12, "actual shares doesn't match quoted shares");
        assertApproxEqAbs(actualAmount0, amount0, 1, "actual amount0 doesn't match quoted amount0");
        assertApproxEqAbs(actualAmount1, amount1, 1, "actual amount1 doesn't match quoted amount1");
    }

    function test_rebalance_basicOrderCreationAndFulfillment(
        uint256 swapAmount,
        bool useVault0,
        bool useVault1,
        uint32 alpha,
        uint24 feeMin,
        uint24 feeMax,
        uint24 feeQuadraticMultiplier,
        bool zeroForOne,
        bool useETH
    ) external {
        swapAmount = bound(swapAmount, 1e6, 1e9);
        feeMin = uint24(bound(feeMin, 2e5, 1e6 - 1));
        feeMax = uint24(bound(feeMax, feeMin, 1e6 - 1));
        alpha = uint32(bound(alpha, 1e3, 12e8));

        MockLDF ldf_ = new MockLDF(address(hub), address(bunniHook), address(quoter));
        bytes32 ldfParams = bytes32(abi.encodePacked(ShiftMode.BOTH, int24(-3) * TICK_SPACING, int16(6), alpha));
        {
            PoolKey memory key_;
            key_.tickSpacing = TICK_SPACING;
            vm.assume(ldf_.isValidParams(key_, TWAP_SECONDS_AGO, ldfParams));
        }
        ldf_.setMinTick(-30); // minTick of MockLDFs need initialization
        (, PoolKey memory key) = _deployPoolAndInitLiquidity(
            useETH ? CurrencyLibrary.ADDRESS_ZERO : Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            useVault0 ? (useETH ? vaultWeth : vault0) : ERC4626(address(0)),
            useVault1 ? vault1 : ERC4626(address(0)),
            ldf_,
            ldfParams,
            abi.encodePacked(
                feeMin,
                feeMax,
                feeQuadraticMultiplier,
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

        // shift liquidity based on direction
        // for zeroForOne: shift left, LDF will demand more token1, so we'll have too much of token0
        // for oneForZero: shift right, LDF will demand more token0, so we'll have too much of token1
        ldf_.setMinTick(zeroForOne ? -40 : -20);

        // Define currencyIn and currencyOut based on direction
        Currency currencyIn = zeroForOne ? (useETH ? Currency.wrap(address(weth)) : key.currency0) : key.currency1;
        Currency currencyOut = zeroForOne ? key.currency1 : (useETH ? Currency.wrap(address(weth)) : key.currency0);
        Currency currencyInRaw = zeroForOne ? key.currency0 : key.currency1;
        Currency currencyOutRaw = zeroForOne ? key.currency1 : key.currency0;

        // make small swap to trigger rebalance
        _mint(key.currency0, address(this), swapAmount);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        vm.recordLogs();
        _swap(key, params, useETH ? swapAmount : 0, "");

        // validate etched order
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory orderEtchedLog;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(floodPlain) && logs[i].topics[0] == IOnChainOrders.OrderEtched.selector) {
                orderEtchedLog = logs[i];
                break;
            }
        }
        assertEq(orderEtchedLog.emitter, address(floodPlain), "emitter not floodPlain");
        assertEq(orderEtchedLog.topics[0], IOnChainOrders.OrderEtched.selector, "not OrderEtched event");
        IFloodPlain.SignedOrder memory signedOrder = abi.decode(orderEtchedLog.data, (IFloodPlain.SignedOrder));
        IFloodPlain.Order memory order = signedOrder.order;
        (, bytes32 permit2Hash) = _hashFloodOrder(order);
        assertEq(
            bunniHook.isValidSignature(permit2Hash, abi.encode(key.toId())),
            IERC1271.isValidSignature.selector,
            "order signature not valid"
        );
        assertEq(order.offerer, address(bunniHook), "offerer not bunniHook");
        assertEq(order.recipient, address(bunniHook), "recipient not bunniHook");
        assertEq(order.offer[0].token, Currency.unwrap(currencyIn), "offer token incorrect");
        assertEq(order.consideration.token, Currency.unwrap(currencyOut), "consideration token incorrect");
        assertEq(order.deadline, vm.getBlockTimestamp() + REBALANCE_ORDER_TTL, "deadline incorrect");
        assertEq(order.preHooks[0].target, address(bunniHook), "preHook target not bunniHook");
        IBunniHook.RebalanceOrderHookArgs memory expectedHookArgs = IBunniHook.RebalanceOrderHookArgs({
            key: key,
            preHookArgs: IBunniHook.RebalanceOrderPreHookArgs({currency: currencyInRaw, amount: order.offer[0].amount}),
            postHookArgs: IBunniHook.RebalanceOrderPostHookArgs({currency: currencyOutRaw})
        });
        assertEq(
            order.preHooks[0].data,
            abi.encodeCall(IBunniHook.rebalanceOrderPreHook, (expectedHookArgs)),
            "preHook data incorrect"
        );
        assertEq(order.postHooks[0].target, address(bunniHook), "postHook target not bunniHook");
        assertEq(
            order.postHooks[0].data,
            abi.encodeCall(IBunniHook.rebalanceOrderPostHook, (expectedHookArgs)),
            "postHook data incorrect"
        );
        assertEq(signedOrder.signature, abi.encode(key.toId()), "signature incorrect");
        uint256 orderPrice = order.consideration.amount.mulDiv(Q96, order.offer[0].amount);
        int24 twapTick = 4;
        uint256 expectedOrderPrice = zeroForOne
            ? uint256(twapTick.getSqrtPriceAtTick()).fullMulX96(twapTick.getSqrtPriceAtTick())
            : uint256((-twapTick).getSqrtPriceAtTick()).fullMulX96((-twapTick).getSqrtPriceAtTick());
        expectedOrderPrice =
            expectedOrderPrice.mulDiv(REBALANCE_MAX_SLIPPAGE_BASE - REBALANCE_MAX_SLIPPAGE, REBALANCE_MAX_SLIPPAGE_BASE);
        assertApproxEqRel(orderPrice, expectedOrderPrice, 1e3, "order price incorrect");

        // fulfill order
        _mint(currencyOut, address(this), order.consideration.amount);
        (uint256 beforeBalance0, uint256 beforeBalance1) = hub.poolBalances(key.toId());
        uint256 beforeFulfillerBalance = currencyOut.balanceOfSelf();
        floodPlain.fulfillOrder(signedOrder);
        (uint256 afterBalance0, uint256 afterBalance1) = hub.poolBalances(key.toId());

        // verify balances
        assertEq(
            beforeFulfillerBalance - currencyOut.balanceOfSelf(),
            order.consideration.amount,
            "didn't take consideration currency from fulfiller"
        );
        uint256 beforeBalanceIn = zeroForOne ? beforeBalance0 : beforeBalance1;
        uint256 afterBalanceIn = zeroForOne ? afterBalance0 : afterBalance1;
        uint256 beforeBalanceOut = zeroForOne ? beforeBalance1 : beforeBalance0;
        uint256 afterBalanceOut = zeroForOne ? afterBalance1 : afterBalance0;

        assertApproxEqAbs(
            beforeBalanceIn - afterBalanceIn, order.offer[0].amount, 10, "offer tokens taken from hub incorrect"
        );
        assertApproxEqAbs(
            afterBalanceOut - beforeBalanceOut,
            order.consideration.amount,
            10,
            "consideration tokens given to hub incorrect"
        );

        {
            // verify excess liquidity after the rebalance
            (uint256 totalLiquidity,,, bool shouldRebalance,,,) = quoter.getExcessLiquidity(key);
            assertFalse(shouldRebalance, "shouldRebalance is still true after rebalance");
            assertEq(totalLiquidity, quoter.getTotalLiquidity(key), "totalLiquidity incorrect");
        }

        // verify surge fee is applied
        (,, uint32 lastSwapTimestamp, uint32 lastSurgeTimestamp) = bunniHook.slot0s(key.toId());
        assertEq(lastSwapTimestamp, uint32(vm.getBlockTimestamp()), "lastSwapTimestamp incorrect");
        assertEq(lastSurgeTimestamp, uint32(vm.getBlockTimestamp()), "lastSurgeTimestamp incorrect");
    }

    function test_rebalance_basicOrderCreationAndFulfillment_carpetedLDF(
        uint256 swapAmount,
        bool useVault0,
        bool useVault1,
        uint32 alpha,
        uint256 weightCarpet,
        uint24 feeMin,
        uint24 feeMax,
        uint24 feeQuadraticMultiplier,
        bool zeroForOne,
        bool useETH
    ) external {
        swapAmount = bound(swapAmount, 1e6, 1e9);
        feeMin = uint24(bound(feeMin, 2e5, 1e6 - 1));
        feeMax = uint24(bound(feeMax, feeMin, 1e6 - 1));
        alpha = uint32(bound(alpha, 1e3, 12e8));
        weightCarpet = bound(weightCarpet, 1e9, type(uint32).max);

        MockCarpetedLDF ldf_ = new MockCarpetedLDF(address(hub), address(bunniHook), address(quoter));
        bytes32 ldfParams =
            bytes32(abi.encodePacked(ShiftMode.BOTH, int24(-3) * TICK_SPACING, int16(6), alpha, uint32(weightCarpet)));
        {
            PoolKey memory key_;
            key_.tickSpacing = TICK_SPACING;
            vm.assume(ldf_.isValidParams(key_, TWAP_SECONDS_AGO, ldfParams));
        }
        ldf_.setMinTick(-30); // minTick of MockLDFs need initialization
        (, PoolKey memory key) = _deployPoolAndInitLiquidity(
            useETH ? CurrencyLibrary.ADDRESS_ZERO : Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            useVault0 ? (useETH ? vaultWeth : vault0) : ERC4626(address(0)),
            useVault1 ? vault1 : ERC4626(address(0)),
            ldf_,
            ldfParams,
            abi.encodePacked(
                feeMin,
                feeMax,
                feeQuadraticMultiplier,
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

        // shift liquidity based on direction
        // for zeroForOne: shift left, LDF will demand more token1, so we'll have too much of token0
        // for oneForZero: shift right, LDF will demand more token0, so we'll have too much of token1
        ldf_.setMinTick(zeroForOne ? -40 : -20);

        // Define currencyIn and currencyOut based on direction
        Currency currencyIn = zeroForOne ? (useETH ? Currency.wrap(address(weth)) : key.currency0) : key.currency1;
        Currency currencyOut = zeroForOne ? key.currency1 : (useETH ? Currency.wrap(address(weth)) : key.currency0);
        Currency currencyInRaw = zeroForOne ? key.currency0 : key.currency1;
        Currency currencyOutRaw = zeroForOne ? key.currency1 : key.currency0;

        // make small swap to trigger rebalance
        _mint(key.currency0, address(this), swapAmount);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        vm.recordLogs();
        _swap(key, params, useETH ? swapAmount : 0, "");

        // validate etched order
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory orderEtchedLog;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(floodPlain) && logs[i].topics[0] == IOnChainOrders.OrderEtched.selector) {
                orderEtchedLog = logs[i];
                break;
            }
        }
        assertEq(orderEtchedLog.emitter, address(floodPlain), "emitter not floodPlain");
        assertEq(orderEtchedLog.topics[0], IOnChainOrders.OrderEtched.selector, "not OrderEtched event");
        IFloodPlain.SignedOrder memory signedOrder = abi.decode(orderEtchedLog.data, (IFloodPlain.SignedOrder));
        IFloodPlain.Order memory order = signedOrder.order;
        (, bytes32 permit2Hash) = _hashFloodOrder(order);
        assertEq(
            bunniHook.isValidSignature(permit2Hash, abi.encode(key.toId())),
            IERC1271.isValidSignature.selector,
            "order signature not valid"
        );
        assertEq(order.offerer, address(bunniHook), "offerer not bunniHook");
        assertEq(order.recipient, address(bunniHook), "recipient not bunniHook");
        assertEq(order.offer[0].token, Currency.unwrap(currencyIn), "offer token incorrect");
        assertEq(order.consideration.token, Currency.unwrap(currencyOut), "consideration token incorrect");
        assertEq(order.deadline, vm.getBlockTimestamp() + REBALANCE_ORDER_TTL, "deadline incorrect");
        assertEq(order.preHooks[0].target, address(bunniHook), "preHook target not bunniHook");
        IBunniHook.RebalanceOrderHookArgs memory expectedHookArgs = IBunniHook.RebalanceOrderHookArgs({
            key: key,
            preHookArgs: IBunniHook.RebalanceOrderPreHookArgs({currency: currencyInRaw, amount: order.offer[0].amount}),
            postHookArgs: IBunniHook.RebalanceOrderPostHookArgs({currency: currencyOutRaw})
        });
        assertEq(
            order.preHooks[0].data,
            abi.encodeCall(IBunniHook.rebalanceOrderPreHook, (expectedHookArgs)),
            "preHook data incorrect"
        );
        assertEq(order.postHooks[0].target, address(bunniHook), "postHook target not bunniHook");
        assertEq(
            order.postHooks[0].data,
            abi.encodeCall(IBunniHook.rebalanceOrderPostHook, (expectedHookArgs)),
            "postHook data incorrect"
        );
        assertEq(signedOrder.signature, abi.encode(key.toId()), "signature incorrect");
        uint256 orderPrice = order.consideration.amount.mulDiv(Q96, order.offer[0].amount);
        int24 twapTick = 4;
        uint256 expectedOrderPrice = zeroForOne
            ? uint256(twapTick.getSqrtPriceAtTick()).fullMulX96(twapTick.getSqrtPriceAtTick())
            : uint256((-twapTick).getSqrtPriceAtTick()).fullMulX96((-twapTick).getSqrtPriceAtTick());
        expectedOrderPrice =
            expectedOrderPrice.mulDiv(REBALANCE_MAX_SLIPPAGE_BASE - REBALANCE_MAX_SLIPPAGE, REBALANCE_MAX_SLIPPAGE_BASE);
        assertApproxEqRel(orderPrice, expectedOrderPrice, 1e3, "order price incorrect");

        // fulfill order
        _mint(currencyOut, address(this), order.consideration.amount);
        (uint256 beforeBalance0, uint256 beforeBalance1) = hub.poolBalances(key.toId());
        uint256 beforeFulfillerBalance = currencyOut.balanceOfSelf();
        floodPlain.fulfillOrder(signedOrder);
        (uint256 afterBalance0, uint256 afterBalance1) = hub.poolBalances(key.toId());

        // verify balances
        assertEq(
            beforeFulfillerBalance - currencyOut.balanceOfSelf(),
            order.consideration.amount,
            "didn't take consideration currency from fulfiller"
        );
        uint256 beforeBalanceIn = zeroForOne ? beforeBalance0 : beforeBalance1;
        uint256 afterBalanceIn = zeroForOne ? afterBalance0 : afterBalance1;
        uint256 beforeBalanceOut = zeroForOne ? beforeBalance1 : beforeBalance0;
        uint256 afterBalanceOut = zeroForOne ? afterBalance1 : afterBalance0;

        assertApproxEqAbs(
            beforeBalanceIn - afterBalanceIn, order.offer[0].amount, 10, "offer tokens taken from hub incorrect"
        );
        assertApproxEqAbs(
            afterBalanceOut - beforeBalanceOut,
            order.consideration.amount,
            10,
            "consideration tokens given to hub incorrect"
        );

        {
            // verify excess liquidity after the rebalance
            (uint256 totalLiquidity,,, bool shouldRebalance,,,) = quoter.getExcessLiquidity(key);
            assertFalse(shouldRebalance, "shouldRebalance is still true after rebalance");
            assertEq(totalLiquidity, quoter.getTotalLiquidity(key), "totalLiquidity incorrect");
        }

        // verify surge fee is applied
        (,, uint32 lastSwapTimestamp, uint32 lastSurgeTimestamp) = bunniHook.slot0s(key.toId());
        assertEq(lastSwapTimestamp, uint32(vm.getBlockTimestamp()), "lastSwapTimestamp incorrect");
        assertEq(lastSurgeTimestamp, uint32(vm.getBlockTimestamp()), "lastSurgeTimestamp incorrect");
    }

    function test_hooklet_basicHookletCalls() external {
        // deploy mock hooklet with all flags
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

        // deploy pool with hooklet
        // this should trigger:
        // - before/afterInitialize
        // - before/afterDeposit
        (Currency currency0, Currency currency1) = (Currency.wrap(address(token0)), Currency.wrap(address(token1)));
        (IBunniToken bunniToken, PoolKey memory key) = _deployPoolAndInitLiquidity(currency0, currency1, hooklet);
        address depositor = address(0x6969);

        // transfer bunniToken
        // this should trigger:
        // - before/afterTransfer
        address recipient = address(0x8008);
        vm.startPrank(depositor);
        bunniToken.transfer(recipient, bunniToken.balanceOf(depositor));
        vm.stopPrank();
        vm.startPrank(recipient);
        bunniToken.transfer(depositor, bunniToken.balanceOf(recipient));
        vm.stopPrank();

        // withdraw liquidity
        // this should trigger:
        // - before/afterWithdraw
        vm.startPrank(depositor);
        hub.withdraw(
            IBunniHub.WithdrawParams({
                poolKey: key,
                recipient: depositor,
                shares: bunniToken.balanceOf(depositor),
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                useQueuedWithdrawal: false
            })
        );
        vm.stopPrank();

        // make swap
        // this should trigger:
        // - before/afterSwap
        _mint(currency0, address(this), 1 ether);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(1 ether),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        _swap(key, params, 0, "");
    }

    function test_rebalance_arb() external {
        uint256 swapAmount = 1e6;
        uint32 alpha = 359541238;
        uint24 feeMin = 0.3e6;
        uint24 feeMax = 0.5e6;
        uint24 feeQuadraticMultiplier = 1e6;

        MockLDF ldf_ = new MockLDF(address(hub), address(bunniHook), address(quoter));
        bytes32 ldfParams = bytes32(abi.encodePacked(ShiftMode.BOTH, int24(-3) * TICK_SPACING, int16(6), alpha));
        ldf_.setMinTick(-30); // minTick of MockLDFs need initialization
        (, PoolKey memory key) = _deployPoolAndInitLiquidity(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            ERC4626(address(0)),
            ERC4626(address(0)),
            ldf_,
            ldfParams,
            abi.encodePacked(
                feeMin,
                feeMax,
                feeQuadraticMultiplier,
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
        _swap(key, params, 0, "");

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
        IFloodPlain.Order memory order = signedOrder.order;

        // prepare deposit data
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
            vaultFee1: 0,
            referrer: address(0)
        });
        _mint(key.currency0, address(this), depositParams.amount0Desired);
        _mint(key.currency1, address(this), depositParams.amount1Desired);

        // fulfill order
        // should revert due to reentrancy
        _mint(key.currency0, address(this), order.consideration.amount);
        bytes memory data = abi.encode(depositParams);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuard__ReentrantCall.selector);
        floodPlain.fulfillOrder(signedOrder, address(this), data);
    }

    function test_avoidTransferringBidTokensDuringRebalance() public {
        // Step 1: Create a new pool
        (IBunniToken bt1, PoolKey memory poolKey1) = _deployPoolAndInitLiquidity();

        // Step 2: Send bids and rent tokens (BT1) to BunniHook
        uint128 minRent = uint128(bt1.totalSupply() * MIN_RENT_MULTIPLIER / 1e18);
        uint128 bidAmount = minRent * 10 days;
        deal(address(bt1), address(this), bidAmount);
        bt1.approve(address(bunniHook), bidAmount);
        bunniHook.bid(
            poolKey1.toId(), address(this), bytes6(abi.encodePacked(uint24(1e3), uint24(2e3))), minRent * 2, bidAmount
        );

        // Record the initial BT1 balance of BunniHook
        uint256 initialBT1Balance = bt1.balanceOf(address(bunniHook));
        assertEq(initialBT1Balance, bidAmount, "BunniHook should have BT1 balance");

        // Step 3: Create a new pool with BT1 and AttackerToken
        ERC20Mock attackerToken = new ERC20Mock();
        MockLDF mockLDF = new MockLDF(address(hub), address(bunniHook), address(quoter));
        mockLDF.setMinTick(-30); // minTick of MockLDFs need initialization

        // approve tokens
        vm.startPrank(address(0x6969));
        bt1.approve(address(PERMIT2), type(uint256).max);
        attackerToken.approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(address(bt1), address(hub), type(uint160).max, type(uint48).max);
        PERMIT2.approve(address(attackerToken), address(hub), type(uint160).max, type(uint48).max);
        vm.stopPrank();

        (Currency currency0, Currency currency1) = address(bt1) < address(attackerToken)
            ? (Currency.wrap(address(bt1)), Currency.wrap(address(attackerToken)))
            : (Currency.wrap(address(attackerToken)), Currency.wrap(address(bt1)));
        (, PoolKey memory poolKey2) = _deployPoolAndInitLiquidity(
            currency0,
            currency1,
            ERC4626(address(0)),
            ERC4626(address(0)),
            mockLDF,
            IHooklet(address(0)),
            bytes32(abi.encodePacked(ShiftMode.BOTH, int24(-3) * TICK_SPACING, int16(6), ALPHA)),
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
            ),
            bytes32(uint256(1))
        );

        // Step 4: Trigger a rebalance for the attacker's pool
        // Shift liquidity to create an imbalance such that we need to swap attackerToken into bt1
        // Shift right if bt1 is token0, shift left if bt1 is token1
        mockLDF.setMinTick(address(bt1) < address(attackerToken) ? -20 : -40);

        // Make a small swap to trigger rebalance
        uint256 swapAmount = 1e6;
        deal(address(bt1), address(this), swapAmount);
        bt1.approve(address(swapper), swapAmount);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: address(bt1) < address(attackerToken),
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: address(bt1) < address(attackerToken)
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        // Record logs to capture the OrderEtched event
        vm.recordLogs();
        swapper.swap(poolKey2, params, type(uint256).max, 0);

        // Find the OrderEtched event
        Vm.Log[] memory logs_ = vm.getRecordedLogs();
        Vm.Log memory orderEtchedLog;
        for (uint256 i = 0; i < logs_.length; i++) {
            if (logs_[i].emitter == address(floodPlain) && logs_[i].topics[0] == IOnChainOrders.OrderEtched.selector) {
                orderEtchedLog = logs_[i];
                break;
            }
        }
        require(orderEtchedLog.emitter == address(floodPlain), "OrderEtched event not found");

        // Decode the order from the event
        IFloodPlain.SignedOrder memory signedOrder = abi.decode(orderEtchedLog.data, (IFloodPlain.SignedOrder));
        IFloodPlain.Order memory order = signedOrder.order;

        // Fulfill the rebalance order
        deal(address(bt1), address(this), order.consideration.amount);
        bt1.approve(address(floodPlain), order.consideration.amount);
        floodPlain.fulfillOrder(signedOrder);

        // Step 5: Verify that the BT1 balance of BunniHook is still bidAmount
        uint256 finalBT1Balance = bt1.balanceOf(address(bunniHook));
        assertEq(finalBT1Balance, bidAmount, "BT1 balance of BunniHook should not change after rebalance");
    }

    function test_idleBalance_rebalanceUpdatesIdleBalance() public {
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
        IFloodPlain.Order memory order = signedOrder.order;

        // fulfill order
        _mint(key.currency0, address(this), order.consideration.amount);
        floodPlain.fulfillOrder(signedOrder);

        // idle balance should be reduced
        IdleBalance idleBalanceAfter = hub.idleBalance(key.toId());
        (uint256 balanceAfter, bool isToken0After) = idleBalanceAfter.fromIdleBalance();
        assertLt(balanceAfter, balanceBefore, "idle balance should be reduced");
        assertFalse(isToken0After, "idle balance should still be in token1");
    }

    function test_PoCVaultDoS() public {
        Currency currency0 = Currency.wrap(address(token0));
        Currency currency1 = Currency.wrap(address(token1));
        ERC4626 vault0_ = vault0;
        ERC4626 vault1_ = vault1;

        (, PoolKey memory key) = _deployPoolAndInitLiquidity(currency0, currency1, vault0_, vault1_);

        uint256 inputAmount = PRECISION / 10;

        _mint(key.currency0, address(this), inputAmount);
        uint256 value = key.currency0.isAddressZero() ? inputAmount : 0;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(inputAmount),
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(3)
        });

        // Set up conditions
        // 1. Ensure that raw balance is greater than the max, hence it would need to trigger the vault
        // deposit
        uint256 amountOfAssetsToBurn = vault0.balanceOf(address(hub)) / 3;
        vm.prank(address(hub));
        vault0.transfer(address(0xdead), amountOfAssetsToBurn);
        // 2. Ensure maxDeposit is 0
        vault0.setMaxDepositFor(address(hub));

        // After the fix has been applied, the following revert will not happen and the swap
        // will be processed successfully
        /* 
        vm.expectRevert(
            abi.encodeWithSelector(
                WrappedError.selector,
                address(bunniHook),
                BunniHook.beforeSwap.selector,
                abi.encodePacked(ERC4626Mock.ZeroAssetsDeposit.selector),
                abi.encodePacked(bytes4(keccak256("HookCallFailed()")))
            )
        ); */
        _swap(key, params, value, "swap");
    }

    // Implementation of IFulfiller interface
    function sourceConsideration(
        bytes28, /* selectorExtension */
        IFloodPlain.Order calldata order,
        address, /* caller */
        bytes calldata data
    ) external returns (uint256) {
        // deposit liquidity between rebalanceOrderPreHook and rebalanceOrderPostHook
        IBunniHub.DepositParams memory depositParams = abi.decode(data, (IBunniHub.DepositParams));
        (, deposit0, deposit1) = hub.deposit(depositParams);

        return order.consideration.amount;
    }
}
