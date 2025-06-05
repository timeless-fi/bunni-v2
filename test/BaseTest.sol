// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.15;

import "forge-std/Test.sol";

import {IFloodPlain} from "flood-contracts/src/interfaces/IFloodPlain.sol";
import {IOnChainOrders} from "flood-contracts/src/interfaces/IOnChainOrders.sol";

import {LibMulticaller} from "multicaller/LibMulticaller.sol";
import {MulticallerEtcher} from "multicaller/MulticallerEtcher.sol";
import {MulticallerWithSender} from "multicaller/MulticallerWithSender.sol";
import {MulticallerWithSigner} from "multicaller/MulticallerWithSigner.sol";

import {IEIP712} from "permit2/src/interfaces/IEIP712.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IERC1271} from "permit2/src/interfaces/IERC1271.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager, PoolKey} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {WETH} from "solady/tokens/WETH.sol";
import {ERC4626} from "solady/tokens/ERC4626.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import "../src/lib/Math.sol";
import "../src/base/Errors.sol";
import "../src/types/LDFType.sol";
import "../src/ldf/ShiftMode.sol";
import "../src/base/SharedStructs.sol";
import {MockLDF} from "./mocks/MockLDF.sol";
import {BunniHub} from "../src/BunniHub.sol";
import {BunniZone} from "../src/BunniZone.sol";
import {BunniHook} from "../src/BunniHook.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {BunniToken} from "../src/BunniToken.sol";
import {Uniswapper} from "./mocks/Uniswapper.sol";
import {HookletMock} from "./mocks/HookletMock.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {PoolState} from "../src/types/PoolState.sol";
import {HookletLib} from "../src/lib/HookletLib.sol";
import {FullMathX96} from "../src/lib/FullMathX96.sol";
import {FloodDeployer} from "./utils/FloodDeployer.sol";
import {IHooklet} from "../src/interfaces/IHooklet.sol";
import {IBunniHub} from "../src/interfaces/IBunniHub.sol";
import {MockCarpetedLDF} from "./mocks/MockCarpetedLDF.sol";
import {IBunniHook} from "../src/interfaces/IBunniHook.sol";
import {Permit2Deployer} from "./utils/Permit2Deployer.sol";
import {BunniHookLogic} from "../src/lib/BunniHookLogic.sol";
import {BunniQuoter} from "../src/periphery/BunniQuoter.sol";
import {IBunniToken} from "../src/interfaces/IBunniToken.sol";
import {OrderHashMemory} from "../src/lib/OrderHashMemory.sol";
import {ReentrancyGuard} from "../src/base/ReentrancyGuard.sol";
import {ERC4626WithFeeMock} from "./mocks/ERC4626WithFeeMock.sol";
import {ERC4626TakeLessMock} from "./mocks/ERC4626TakeLessMock.sol";
import {GeometricDistribution} from "../src/ldf/GeometricDistribution.sol";
import {DoubleGeometricDistribution} from "../src/ldf/DoubleGeometricDistribution.sol";
import {ERC4626Mock, MaliciousERC4626, ERC4626FeeMock} from "./mocks/ERC4626Mock.sol";
import {ILiquidityDensityFunction} from "../src/interfaces/ILiquidityDensityFunction.sol";

abstract contract BaseTest is Test, Permit2Deployer, FloodDeployer {
    using TickMath for *;
    using FullMathX96 for *;
    using SafeCastLib for *;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;

    /// @dev ERC-7751 error for wrapping bubbled up reverts
    error WrappedError(address target, bytes4 selector, bytes reason, bytes details);

    enum HookUnlockCallbackType {
        BURN_AND_TAKE,
        SETTLE_AND_MINT,
        CLAIM_FEES
    }

    uint256 internal constant PRECISION = 10 ** 18;
    uint8 internal constant DECIMALS = 18;
    int24 internal constant TICK_SPACING = 10;
    uint32 internal constant HOOK_FEE_MODIFIER = 0.1e6;
    uint48 internal constant K = 7200;
    uint32 internal constant ALPHA = 0.7e8;
    uint256 internal constant MAX_ERROR = 1e9;
    uint24 internal constant FEE_MIN = 0.0001e6;
    uint24 internal constant FEE_MAX = 0.1e6;
    uint24 internal constant FEE_QUADRATIC_MULTIPLIER = 0.5e6;
    uint24 internal constant FEE_TWAP_SECONDS_AGO = 30 minutes;
    address internal constant HOOK_FEE_RECIPIENT = address(0xfee);
    address internal constant HOOK_FEE_RECIPIENT_CONTROLLER = address(0xf00d);
    uint24 internal constant TWAP_SECONDS_AGO = 1 days;
    uint16 internal constant SURGE_HALFLIFE = 1 minutes;
    uint16 internal constant SURGE_AUTOSTART_TIME = 2 minutes;
    uint16 internal constant VAULT_SURGE_THRESHOLD_0 = 1e4; // 0.01% change in share price
    uint16 internal constant VAULT_SURGE_THRESHOLD_1 = 1e3; // 0.1% change in share price
    uint256 internal constant VAULT_FEE = 0.03e18;
    uint16 internal constant REBALANCE_THRESHOLD = 100; // 1 / 100 = 1%
    uint16 internal constant REBALANCE_MAX_SLIPPAGE = 1; // 5%
    uint16 internal constant REBALANCE_TWAP_SECONDS_AGO = 1 hours;
    uint16 internal constant REBALANCE_ORDER_TTL = 10 minutes;
    uint32 internal constant ORACLE_MIN_INTERVAL = 1 hours;
    uint24 internal constant POOL_MAX_AMAMM_FEE = 0.05e6; // 5%
    uint48 internal constant MIN_RENT_MULTIPLIER = 1e10;
    uint256 internal constant HOOK_FLAGS = Hooks.AFTER_INITIALIZE_FLAG + Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        + Hooks.BEFORE_SWAP_FLAG + Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;

    IPoolManager internal poolManager;
    ERC20Mock internal token0;
    ERC20Mock internal token1;
    ERC4626Mock internal vault0;
    ERC4626Mock internal vault1;
    ERC4626Mock internal vaultWeth;
    ERC4626WithFeeMock internal vault0WithFee;
    ERC4626WithFeeMock internal vault1WithFee;
    ERC4626WithFeeMock internal vaultWethWithFee;
    ERC4626TakeLessMock internal vault0TakeLess;
    IBunniHub internal hub;
    BunniHook internal bunniHook;
    BunniQuoter internal quoter;
    ILiquidityDensityFunction internal ldf;
    Uniswapper internal swapper;
    WETH internal weth;
    IFloodPlain internal floodPlain;
    BunniZone internal zone;
    uint256 deposit0;
    uint256 deposit1;

    function setUp() public virtual {
        vm.warp(1e9); // init block timestamp to reasonable value

        weth = new WETH();
        _deployPermit2(vm);
        MulticallerEtcher.multicallerWithSender();
        MulticallerEtcher.multicallerWithSigner();

        floodPlain = _deployFlood(address(PERMIT2));

        // initialize uniswap
        token0 = new ERC20Mock();
        token1 = new ERC20Mock();
        if (address(token0) >= address(token1)) {
            (token0, token1) = (token1, token0);
        }
        poolManager = new PoolManager(address(this));

        // deploy vaults
        vault0 = new ERC4626Mock(token0);
        vault1 = new ERC4626Mock(token1);
        vaultWeth = new ERC4626Mock(IERC20(address(weth)));
        vault0WithFee = new ERC4626WithFeeMock(token0);
        vault1WithFee = new ERC4626WithFeeMock(token1);
        vaultWethWithFee = new ERC4626WithFeeMock(IERC20(address(weth)));
        vault0TakeLess = new ERC4626TakeLessMock(token0);

        // mint some initial tokens to the vaults to change the share price
        _mint(Currency.wrap(address(token0)), address(this), 2 ether);
        _mint(Currency.wrap(address(token1)), address(this), 2 ether);
        _mint(Currency.wrap(address(weth)), address(this), 2 ether);

        token0.approve(address(vault0), type(uint256).max);
        vault0.deposit(1 ether, address(this));
        _mint(Currency.wrap(address(token0)), address(vault0), 1 ether);

        token1.approve(address(vault1), type(uint256).max);
        vault1.deposit(1 ether, address(this));
        _mint(Currency.wrap(address(token1)), address(vault1), 1 ether);

        weth.approve(address(vaultWeth), type(uint256).max);
        vaultWeth.deposit(1 ether, address(this));
        _mint(Currency.wrap(address(weth)), address(vaultWeth), 1 ether);

        token0.approve(address(vault0WithFee), type(uint256).max);
        vault0WithFee.deposit(1 ether, address(this));
        _mint(Currency.wrap(address(token0)), address(vault0WithFee), 1 ether);

        token1.approve(address(vault1WithFee), type(uint256).max);
        vault1WithFee.deposit(1 ether, address(this));
        _mint(Currency.wrap(address(token1)), address(vault1WithFee), 1 ether);

        weth.approve(address(vaultWethWithFee), type(uint256).max);
        vaultWethWithFee.deposit(1 ether, address(this));
        _mint(Currency.wrap(address(weth)), address(vaultWethWithFee), 1 ether);

        // deploy swapper
        swapper = new Uniswapper(poolManager);

        // initialize bunni hub
        IBunniHook[] memory hookWhitelist = new IBunniHook[](0);
        hub = new BunniHub(poolManager, weth, PERMIT2, new BunniToken(), address(this), hookWhitelist);

        // deploy zone
        zone = new BunniZone(address(this), new address[](0));

        // initialize bunni hook
        bytes32 hookSalt;
        unchecked {
            bytes memory hookCreationCode = abi.encodePacked(
                type(BunniHook).creationCode,
                abi.encode(poolManager, hub, floodPlain, weth, zone, address(this), HOOK_FEE_RECIPIENT_CONTROLLER, K)
            );
            for (uint256 offset; offset < 100000; offset++) {
                hookSalt = bytes32(offset);
                address hookDeployed = computeAddress(address(this), hookSalt, hookCreationCode);
                if (uint160(bytes20(hookDeployed)) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS && hookDeployed.code.length == 0)
                {
                    break;
                }
            }
        }
        bunniHook = new BunniHook{salt: hookSalt}(
            poolManager, hub, floodPlain, weth, zone, address(this), HOOK_FEE_RECIPIENT_CONTROLLER, K
        );
        vm.label(address(bunniHook), "BunniHook");

        // whitelist hook
        hub.setHookWhitelist(bunniHook, true);

        // deploy quoter
        quoter = new BunniQuoter(hub);

        // initialize LDF
        ldf = new GeometricDistribution(address(hub), address(bunniHook), address(quoter));

        // approve tokens
        token0.approve(address(PERMIT2), type(uint256).max);
        token0.approve(address(swapper), type(uint256).max);
        token0.approve(address(floodPlain), type(uint256).max);
        token1.approve(address(PERMIT2), type(uint256).max);
        token1.approve(address(swapper), type(uint256).max);
        token1.approve(address(floodPlain), type(uint256).max);
        weth.approve(address(PERMIT2), type(uint256).max);
        weth.approve(address(swapper), type(uint256).max);
        weth.approve(address(floodPlain), type(uint256).max);

        // permit2 approve tokens to hub
        PERMIT2.approve(address(token0), address(hub), type(uint160).max, type(uint48).max);
        PERMIT2.approve(address(token1), address(hub), type(uint160).max, type(uint48).max);
        PERMIT2.approve(address(weth), address(hub), type(uint160).max, type(uint48).max);

        // whitelist address(this) as fulfiller
        zone.setIsWhitelisted(address(this), true);
    }

    receive() external payable {}

    /// -----------------------------------------------------------------------
    /// Internal utils
    /// -----------------------------------------------------------------------

    function _makeDeposit(PoolKey memory key, uint256 depositAmount0, uint256 depositAmount1)
        internal
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        return _makeDeposit(key, depositAmount0, depositAmount1, address(this), "");
    }

    function _makeDeposit(
        PoolKey memory key_,
        uint256 depositAmount0,
        uint256 depositAmount1,
        address depositor,
        string memory snapLabel
    ) internal returns (uint256 shares, uint256 amount0, uint256 amount1) {
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
        IBunniHub hub_ = hub;
        vm.startPrank(depositor);
        (shares, amount0, amount1) = hub_.deposit{value: value}(depositParams);
        if (bytes(snapLabel).length > 0) {
            vm.snapshotGasLastCall(snapLabel);
        }
        vm.stopPrank();
    }

    function _makeDepositWithFee(
        PoolKey memory key_,
        uint256 depositAmount0,
        uint256 depositAmount1,
        address depositor,
        uint256 vaultFee0,
        uint256 vaultFee1,
        string memory snapLabel
    ) internal returns (uint256 shares, uint256 amount0, uint256 amount1) {
        // mint tokens
        uint256 value;
        if (key_.currency0.isAddressZero()) {
            value = depositAmount0.divWadUp(WAD - vaultFee0);
        }
        _mint(key_.currency0, depositor, depositAmount0.divWadUp(WAD - vaultFee0));
        _mint(key_.currency1, depositor, depositAmount1.divWadUp(WAD - vaultFee1));

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
            vaultFee0: vaultFee0,
            vaultFee1: vaultFee1
        });
        IBunniHub hub_ = hub;
        vm.startPrank(depositor);
        (shares, amount0, amount1) = hub_.deposit{value: value}(depositParams);
        if (bytes(snapLabel).length > 0) {
            vm.snapshotGasLastCall(snapLabel);
        }
        vm.stopPrank();
    }

    function _vaultBalanceOf(ERC4626 vault, address account) internal view returns (uint256) {
        if (address(vault) == address(0)) return 0;
        return vault.balanceOf(account);
    }

    function _vaultPreviewRedeem(ERC4626 vault, uint256 amount) internal view returns (uint256) {
        if (address(vault) == address(0)) return 0;
        return vault.previewRedeem(amount);
    }

    function _mint(Currency currency, address to, uint256 amount) internal {
        if (currency.isAddressZero()) {
            vm.deal(to, to.balance + amount);
        } else if (Currency.unwrap(currency) == address(weth)) {
            vm.deal(address(this), address(this).balance + amount);
            weth.deposit{value: amount}();
            weth.transfer(to, amount);
        } else {
            deal(Currency.unwrap(currency), to, currency.balanceOf(to) + amount);
        }
    }

    function _deployPoolAndInitLiquidity() internal returns (IBunniToken bunniToken, PoolKey memory key) {
        return _deployPoolAndInitLiquidity(
            Currency.wrap(address(token0)), Currency.wrap(address(token1)), ERC4626(address(0)), ERC4626(address(0))
        );
    }

    function _deployPoolAndInitLiquidity(Currency currency0, Currency currency1)
        internal
        returns (IBunniToken bunniToken, PoolKey memory key)
    {
        return _deployPoolAndInitLiquidity(currency0, currency1, ERC4626(address(0)), ERC4626(address(0)));
    }

    function _deployPoolAndInitLiquidity(Currency currency0, Currency currency1, IHooklet hooklet)
        internal
        returns (IBunniToken bunniToken, PoolKey memory key)
    {
        return _deployPoolAndInitLiquidity(
            currency0, currency1, ERC4626(address(0)), ERC4626(address(0)), hooklet, bytes32(0)
        );
    }

    function _deployPoolAndInitLiquidity(Currency currency0, Currency currency1, bytes32 salt)
        internal
        returns (IBunniToken bunniToken, PoolKey memory key)
    {
        return _deployPoolAndInitLiquidity(
            currency0, currency1, ERC4626(address(0)), ERC4626(address(0)), IHooklet(address(0)), salt
        );
    }

    function _deployPoolAndInitLiquidity(Currency currency0, Currency currency1, ERC4626 vault0_, ERC4626 vault1_)
        internal
        returns (IBunniToken bunniToken, PoolKey memory key)
    {
        return _deployPoolAndInitLiquidity(currency0, currency1, vault0_, vault1_, IHooklet(address(0)), bytes32(0));
    }

    function _deployPoolAndInitLiquidity(
        Currency currency0,
        Currency currency1,
        ERC4626 vault0_,
        ERC4626 vault1_,
        IHooklet hooklet,
        bytes32 salt
    ) internal returns (IBunniToken bunniToken, PoolKey memory key) {
        return _deployPoolAndInitLiquidity(
            currency0,
            currency1,
            vault0_,
            vault1_,
            ldf,
            hooklet,
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
            salt
        );
    }

    function _deployPoolAndInitLiquidity(
        Currency currency0,
        Currency currency1,
        ERC4626 vault0_,
        ERC4626 vault1_,
        ILiquidityDensityFunction ldf_
    ) internal returns (IBunniToken bunniToken, PoolKey memory key) {
        return _deployPoolAndInitLiquidity(
            currency0,
            currency1,
            vault0_,
            vault1_,
            ldf_,
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
            bytes32(0)
        );
    }

    function _deployPoolAndInitLiquidity(ILiquidityDensityFunction ldf_, bytes32 ldfParams)
        internal
        returns (IBunniToken bunniToken, PoolKey memory key)
    {
        return _deployPoolAndInitLiquidity(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            ERC4626(address(0)),
            ERC4626(address(0)),
            ldf_,
            IHooklet(address(0)),
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
            ),
            bytes32(0)
        );
    }

    function _deployPoolAndInitLiquidity(
        Currency currency0,
        Currency currency1,
        ERC4626 vault0_,
        ERC4626 vault1_,
        bytes32 ldfParams,
        bytes memory hookParams
    ) internal returns (IBunniToken bunniToken, PoolKey memory key) {
        return _deployPoolAndInitLiquidity(
            currency0, currency1, vault0_, vault1_, ldf, IHooklet(address(0)), ldfParams, hookParams, bytes32(0)
        );
    }

    function _deployPoolAndInitLiquidity(
        Currency currency0,
        Currency currency1,
        ERC4626 vault0_,
        ERC4626 vault1_,
        ILiquidityDensityFunction ldf_,
        bytes32 ldfParams,
        bytes memory hookParams
    ) internal returns (IBunniToken bunniToken, PoolKey memory key) {
        return _deployPoolAndInitLiquidity(
            currency0, currency1, vault0_, vault1_, ldf_, IHooklet(address(0)), ldfParams, hookParams, bytes32(0)
        );
    }

    function _deployPoolAndInitLiquidity(
        Currency currency0,
        Currency currency1,
        ERC4626 vault0_,
        ERC4626 vault1_,
        uint256 depositAmount0,
        uint256 depositAmount1,
        ILiquidityDensityFunction ldf_,
        bytes32 ldfParams,
        bytes memory hookParams
    ) internal returns (IBunniToken bunniToken, PoolKey memory key) {
        return _deployPoolAndInitLiquidity(
            currency0,
            currency1,
            vault0_,
            vault1_,
            depositAmount0,
            depositAmount1,
            ldf_,
            IHooklet(address(0)),
            ldfParams,
            hookParams,
            bytes32(0)
        );
    }

    function _deployPoolAndInitLiquidity(
        Currency currency0,
        Currency currency1,
        ERC4626 vault0_,
        ERC4626 vault1_,
        ILiquidityDensityFunction ldf_,
        IHooklet hooklet,
        bytes32 ldfParams,
        bytes memory hookParams,
        bytes32 salt
    ) internal returns (IBunniToken bunniToken, PoolKey memory key) {
        // initialize bunni
        (bunniToken, key) = hub.deployBunniToken(
            IBunniHub.DeployBunniTokenParams({
                currency0: currency0,
                currency1: currency1,
                tickSpacing: TICK_SPACING,
                twapSecondsAgo: TWAP_SECONDS_AGO,
                liquidityDensityFunction: ldf_,
                hooklet: hooklet,
                ldfType: LDFType.DYNAMIC_AND_STATEFUL,
                ldfParams: ldfParams,
                hooks: bunniHook,
                hookParams: hookParams,
                vault0: vault0_,
                vault1: vault1_,
                minRawTokenRatio0: 0.08e6,
                targetRawTokenRatio0: 0.1e6,
                maxRawTokenRatio0: 0.12e6,
                minRawTokenRatio1: 0.08e6,
                targetRawTokenRatio1: 0.1e6,
                maxRawTokenRatio1: 0.12e6,
                sqrtPriceX96: TickMath.getSqrtPriceAtTick(4),
                name: bytes32("BunniToken"),
                symbol: bytes32("BUNNI-LP"),
                owner: address(this),
                metadataURI: "metadataURI",
                salt: salt
            })
        );

        // make initial deposit to avoid accounting for MIN_INITIAL_SHARES
        uint256 depositAmount0 = PRECISION;
        uint256 depositAmount1 = PRECISION;
        vm.startPrank(address(0x6969));
        token0.approve(address(PERMIT2), type(uint256).max);
        token1.approve(address(PERMIT2), type(uint256).max);
        weth.approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(address(token0), address(hub), type(uint160).max, type(uint48).max);
        PERMIT2.approve(address(token1), address(hub), type(uint160).max, type(uint48).max);
        PERMIT2.approve(address(weth), address(hub), type(uint160).max, type(uint48).max);
        vm.stopPrank();
        uint256 vaultFee0 = (
            address(vault0_) == address(vault0WithFee) || address(vault0_) == address(vault1WithFee)
                || address(vault0_) == address(vaultWethWithFee)
        ) ? VAULT_FEE : (address(vault0_) == address(vault0TakeLess) ? 0.5e18 : 0);
        uint256 vaultFee1 = (
            address(vault1_) == address(vault0WithFee) || address(vault1_) == address(vault1WithFee)
                || address(vault1_) == address(vaultWethWithFee)
        ) ? VAULT_FEE : 0;
        _makeDepositWithFee(key, depositAmount0, depositAmount1, address(0x6969), vaultFee0, vaultFee1, "");
    }

    function _deployPoolAndInitLiquidity(
        Currency currency0,
        Currency currency1,
        ERC4626 vault0_,
        ERC4626 vault1_,
        uint256 depositAmount0,
        uint256 depositAmount1,
        ILiquidityDensityFunction ldf_,
        IHooklet hooklet,
        bytes32 ldfParams,
        bytes memory hookParams,
        bytes32 salt
    ) internal returns (IBunniToken bunniToken, PoolKey memory key) {
        // initialize bunni
        (bunniToken, key) = hub.deployBunniToken(
            IBunniHub.DeployBunniTokenParams({
                currency0: currency0,
                currency1: currency1,
                tickSpacing: TICK_SPACING,
                twapSecondsAgo: TWAP_SECONDS_AGO,
                liquidityDensityFunction: ldf_,
                hooklet: hooklet,
                ldfType: LDFType.DYNAMIC_AND_STATEFUL,
                ldfParams: ldfParams,
                hooks: bunniHook,
                hookParams: hookParams,
                vault0: vault0_,
                vault1: vault1_,
                minRawTokenRatio0: 0.08e6,
                targetRawTokenRatio0: 0.1e6,
                maxRawTokenRatio0: 0.12e6,
                minRawTokenRatio1: 0.08e6,
                targetRawTokenRatio1: 0.1e6,
                maxRawTokenRatio1: 0.12e6,
                sqrtPriceX96: TickMath.getSqrtPriceAtTick(4),
                name: bytes32("BunniToken"),
                symbol: bytes32("BUNNI-LP"),
                owner: address(this),
                metadataURI: "metadataURI",
                salt: salt
            })
        );

        // make initial deposit to avoid accounting for MIN_INITIAL_SHARES
        vm.startPrank(address(0x6969));
        token0.approve(address(PERMIT2), type(uint256).max);
        token1.approve(address(PERMIT2), type(uint256).max);
        weth.approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(address(token0), address(hub), type(uint160).max, type(uint48).max);
        PERMIT2.approve(address(token1), address(hub), type(uint160).max, type(uint48).max);
        PERMIT2.approve(address(weth), address(hub), type(uint160).max, type(uint48).max);
        vm.stopPrank();
        uint256 vaultFee0 = (
            address(vault0_) == address(vault0WithFee) || address(vault0_) == address(vault1WithFee)
                || address(vault0_) == address(vaultWethWithFee)
        ) ? VAULT_FEE : (address(vault0_) == address(vault0TakeLess) ? 0.5e18 : 0);
        uint256 vaultFee1 = (
            address(vault1_) == address(vault0WithFee) || address(vault1_) == address(vault1WithFee)
                || address(vault1_) == address(vaultWethWithFee)
        ) ? VAULT_FEE : 0;
        _makeDepositWithFee(key, depositAmount0, depositAmount1, address(0x6969), vaultFee0, vaultFee1, "");
    }

    function _swap(PoolKey memory key, IPoolManager.SwapParams memory params, uint256 value, string memory snapLabel)
        internal
    {
        Uniswapper swapper_ = swapper;
        if (bytes(snapLabel).length > 0) {
            swapper_.swap{value: value}(key, params, type(uint256).max, 0);
            vm.snapshotGasLastCall(snapLabel);
        } else {
            swapper_.swap{value: value}(key, params, type(uint256).max, 0);
        }
    }

    function _trySwap(PoolKey memory key, IPoolManager.SwapParams memory params, uint256 value, string memory snapLabel)
        internal
        returns (bool success)
    {
        Uniswapper swapper_ = swapper;
        if (bytes(snapLabel).length > 0) {
            try swapper_.swap{value: value}(key, params, type(uint256).max, 0) {
                vm.snapshotGasLastCall(snapLabel);
                success = true;
            } catch {
                success = false;
            }
        } else {
            try swapper_.swap{value: value}(key, params, type(uint256).max, 0) {
                success = true;
            } catch {
                success = false;
            }
        }
    }

    /// @dev The hash that Permit2 uses when verifying the order's signature.
    /// See https://github.com/Uniswap/permit2/blob/cc56ad0f3439c502c246fc5cfcc3db92bb8b7219/src/SignatureTransfer.sol#L65
    /// Always calls permit2 for the domain separator to maintain cross-chain replay protection in the event of a fork
    /// Also returns the Flood order hash
    function _hashFloodOrder(IFloodPlain.Order memory order)
        internal
        view
        returns (bytes32 orderHash, bytes32 permit2Hash)
    {
        (orderHash, permit2Hash) = OrderHashMemory.hashAsWitness(order, address(floodPlain));
        permit2Hash = keccak256(abi.encodePacked("\x19\x01", IEIP712(PERMIT2).DOMAIN_SEPARATOR(), permit2Hash));
    }

    /// @notice Precompute a contract address deployed via CREATE2
    /// @param deployer The address that will deploy the hook. In `forge test`, this will be the test contract `address(this)` or the pranking address
    ///                 In `forge script`, this should be `0x4e59b44847b379578588920cA78FbF26c0B4956C` (CREATE2 Deployer Proxy)
    /// @param salt The salt used to deploy the hook
    /// @param creationCode The creation code of a hook contract
    function computeAddress(address deployer, bytes32 salt, bytes memory creationCode)
        public
        pure
        returns (address hookAddress)
    {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer, salt, keccak256(creationCode)))))
        );
    }

    function skipBlocks(uint256 numBlocks) internal {
        vm.roll(vm.getBlockNumber() + numBlocks);
    }

    function _execTestAcrossScenarios(
        function (
        uint256,
        uint256,
        Currency,
        Currency,
        ERC4626,
        ERC4626,
        string memory
        ) fn,
        uint256 depositAmount0,
        uint256 depositAmount1,
        string memory label
    ) internal {
        uint256 snapshotId = vm.snapshot();

        fn(
            depositAmount0,
            depositAmount1,
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            ERC4626(address(0)),
            ERC4626(address(0)),
            string.concat(label, ", token0 no native no vault, token1 no native no vault")
        );
        vm.revertTo(snapshotId);

        fn(
            depositAmount0,
            depositAmount1,
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            ERC4626(address(0)),
            vault1,
            string.concat(label, ", token0 no native no vault, token1 no native yes vault")
        );
        vm.revertTo(snapshotId);

        fn(
            depositAmount0,
            depositAmount1,
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            vault0,
            vault1,
            string.concat(label, ", token0 no native yes vault, token1 no native yes vault")
        );
        vm.revertTo(snapshotId);

        fn(
            depositAmount0,
            depositAmount1,
            CurrencyLibrary.ADDRESS_ZERO,
            Currency.wrap(address(token1)),
            ERC4626(address(0)),
            ERC4626(address(0)),
            string.concat(label, ", token0 yes native no vault, token1 no native no vault")
        );
        vm.revertTo(snapshotId);

        fn(
            depositAmount0,
            depositAmount1,
            CurrencyLibrary.ADDRESS_ZERO,
            Currency.wrap(address(token1)),
            ERC4626(address(0)),
            vault1,
            string.concat(label, ", token0 yes native no vault, token1 no native yes vault")
        );
        vm.revertTo(snapshotId);

        fn(
            depositAmount0,
            depositAmount1,
            CurrencyLibrary.ADDRESS_ZERO,
            Currency.wrap(address(token1)),
            vaultWeth,
            ERC4626(address(0)),
            string.concat(label, ", token0 yes native yes vault, token1 no native no vault")
        );
        vm.revertTo(snapshotId);

        fn(
            depositAmount0,
            depositAmount1,
            CurrencyLibrary.ADDRESS_ZERO,
            Currency.wrap(address(token1)),
            vaultWeth,
            vault1,
            string.concat(label, ", token0 yes native yes vault, token1 no native yes vault")
        );
        vm.revertTo(snapshotId);

        fn(
            depositAmount0,
            depositAmount1,
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            vault0WithFee,
            vault1WithFee,
            string.concat(label, ", token0 no native yes vault with fee, token1 no native yes vault with fee")
        );
        vm.revertTo(snapshotId);

        fn(
            depositAmount0,
            depositAmount1,
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            ERC4626(address(0)),
            vault1WithFee,
            string.concat(label, ", token0 no native no vault, token1 no native yes vault with fee")
        );
        vm.revertTo(snapshotId);

        fn(
            depositAmount0,
            depositAmount1,
            CurrencyLibrary.ADDRESS_ZERO,
            Currency.wrap(address(token1)),
            vaultWethWithFee,
            ERC4626(address(0)),
            string.concat(label, ", token0 yes native yes vault with fee, token1 no native no vault")
        );
        vm.revertTo(snapshotId);

        fn(
            depositAmount0,
            depositAmount1,
            CurrencyLibrary.ADDRESS_ZERO,
            Currency.wrap(address(token1)),
            vaultWethWithFee,
            vault1WithFee,
            string.concat(label, ", token0 yes native yes vault with fee, token1 no native yes vault with fee")
        );
        vm.revertTo(snapshotId);
    }
}
