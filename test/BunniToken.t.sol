// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {LibString} from "solady/utils/LibString.sol";

import "./BaseTest.sol";

contract BunniTokenTest is BaseTest, IUnlockCallback {
    using LibString for *;
    using CurrencyLibrary for Currency;

    uint256 internal constant MAX_REL_ERROR = 1e4;

    IBunniToken internal bunniToken;
    Currency internal currency0;
    Currency internal currency1;
    PoolKey internal key;

    function setUp() public override {
        super.setUp();

        currency0 = CurrencyLibrary.ADDRESS_ZERO;
        currency1 = Currency.wrap(address(token1));

        // deploy BunniToken
        bytes32 ldfParams = bytes32(abi.encodePacked(ShiftMode.BOTH, int24(-30), int16(6), ALPHA));
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
        (bunniToken, key) = hub.deployBunniToken(
            IBunniHub.DeployBunniTokenParams({
                currency0: currency0,
                currency1: currency1,
                tickSpacing: 10,
                twapSecondsAgo: 7 days,
                liquidityDensityFunction: ldf,
                hooklet: IHooklet(address(0)),
                ldfType: LDFType.DYNAMIC_AND_STATEFUL,
                ldfParams: ldfParams,
                hooks: bunniHook,
                hookParams: hookParams,
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
                symbol: "BUNNI",
                owner: address(this),
                metadataURI: "",
                salt: bytes32(0)
            })
        );

        poolManager.setOperator(address(bunniToken), true);
    }

    function test_bunniToken_multicall() external {
        // make deposit
        (uint256 shares) =
            _makeDeposit({key_: key, depositAmount0: 1 ether, depositAmount1: 1 ether, depositor: address(this)});

        // multitransfer
        uint256 N = 10;
        address[] memory targets = new address[](N);
        bytes[] memory data = new bytes[](N);
        uint256[] memory values = new uint256[](N);
        for (uint256 i; i < N; i++) {
            targets[i] = address(bunniToken);
            data[i] = abi.encodeCall(IERC20.transfer, (address(uint160(i + 1)), shares / N));
        }
        MulticallerWithSender(payable(LibMulticaller.MULTICALLER_WITH_SENDER)).aggregateWithSender(
            targets, data, values
        );
        for (uint256 i; i < N; i++) {
            assertEq(bunniToken.balanceOf(address(uint160(i + 1))), shares / N, "balance incorrect");
        }
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Mint claim tokens of a currency
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        // decode input
        (Currency token, uint256 amount) = abi.decode(data, (Currency, uint256));

        // mint tokens
        _mint(token, address(this), amount);

        // mint claim tokens
        poolManager.mint(address(this), token.toId(), amount);
        poolManager.sync(token);
        if (token.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            token.transfer(address(poolManager), amount);
            poolManager.settle();
        }

        // fallback
        return bytes("");
    }

    function _makeDeposit(PoolKey memory key_, uint256 depositAmount0, uint256 depositAmount1, address depositor)
        internal
        returns (uint256 shares)
    {
        // mint tokens
        uint256 value;
        if (key_.currency0.isAddressZero()) {
            value = depositAmount0;
        }
        _mint(key_.currency0, depositor, depositAmount0);
        _mint(key_.currency1, depositor, depositAmount1);

        // deposit tokens
        IBunniHub.DepositParams memory depositParams = IBunniHub.DepositParams({
            poolKey: key_,
            amount0Desired: depositAmount0,
            amount1Desired: depositAmount1,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp,
            recipient: depositor,
            refundRecipient: depositor,
            vaultFee0: 0,
            vaultFee1: 0
        });
        vm.startPrank(depositor);
        token1.approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(address(token1), address(hub), type(uint160).max, type(uint48).max);
        (shares,,) = hub.deposit{value: value}(depositParams);
        vm.stopPrank();
    }
}
