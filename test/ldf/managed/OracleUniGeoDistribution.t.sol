// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {MockOracle} from "../../mocks/MockOracle.sol";
import {LDFType} from "../../../src/types/LDFType.sol";
import {OracleUniGeoDistribution} from "../../../src/ldf/managed/OracleUniGeoDistribution.sol";
import {LibOracleUniGeoDistribution} from "../../../src/ldf/managed/LibOracleUniGeoDistribution.sol";
import {ERC20Mock} from "../../mocks/ERC20Mock.sol";
import {LibUniformDistribution} from "../../../src/ldf/LibUniformDistribution.sol";
import {LibGeometricDistribution} from "../../../src/ldf/LibGeometricDistribution.sol";

contract OracleUniGeoDistributionTest is Test {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant Q96 = 1 << 96;

    OracleUniGeoDistribution ldf;
    OracleUniGeoDistribution ldfReversed;
    MockOracle oracle;
    ERC20Mock bond;
    ERC20Mock stablecoin;
    address hub;
    IHooks hook;
    address quoter;
    address owner;

    int24 constant TICK_SPACING = 10;

    function setUp() public {
        // Setup mock contracts and addresses
        oracle = new MockOracle();

        // Create deterministic addresses to ensure bond < stablecoin
        address bondAddr = address(0x1111111111111111111111111111111111111111);
        address stablecoinAddr = address(0x2222222222222222222222222222222222222222);

        // No need to actually deploy tokens since the ldf only uses the addresses
        bond = ERC20Mock(bondAddr);
        stablecoin = ERC20Mock(stablecoinAddr);

        // Verify address ordering
        assertTrue(
            address(bond) < address(stablecoin), "Setup failed: bond address must be less than stablecoin address"
        );

        hub = address(this); // allow test contract to call LDFs
        hook = IHooks(makeAddr("hook"));
        quoter = makeAddr("quoter");
        owner = makeAddr("owner");

        // Deploy LDF with bond < stablecoin
        ldf = new OracleUniGeoDistribution(
            hub, address(hook), quoter, owner, oracle, Currency.wrap(address(bond)), Currency.wrap(address(stablecoin))
        );

        // Deploy LDF with bond > stablecoin (reversed order)
        ldfReversed = new OracleUniGeoDistribution(
            hub, address(hook), quoter, owner, oracle, Currency.wrap(address(stablecoin)), Currency.wrap(address(bond))
        );
    }

    function test_initialization() public view {
        // Test bond < stablecoin case
        assertEq(address(ldf.oracle()), address(oracle), "Oracle address mismatch");
        assertEq(Currency.unwrap(ldf.bond()), address(bond), "Bond address mismatch");
        assertEq(Currency.unwrap(ldf.stablecoin()), address(stablecoin), "Stablecoin address mismatch");
        assertTrue(ldf.bondLtStablecoin(), "Bond should be less than stablecoin");

        // Test bond > stablecoin case
        assertEq(address(ldfReversed.oracle()), address(oracle), "Oracle address mismatch (reversed)");
        assertEq(Currency.unwrap(ldfReversed.bond()), address(stablecoin), "Bond address mismatch (reversed)");
        assertEq(Currency.unwrap(ldfReversed.stablecoin()), address(bond), "Stablecoin address mismatch (reversed)");
        assertFalse(ldfReversed.bondLtStablecoin(), "Bond should be greater than stablecoin");
    }

    function test_query_initial() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(bond)),
            currency1: Currency.wrap(address(stablecoin)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: hook
        });

        oracle.setFloorPrice(1e18); // Set initial price at 1.0

        // Test bond < stablecoin case
        {
            // Uniform [0, 10 * TICK_SPACING]
            bytes32 ldfParams = ldf.encodeLdfParams({
                distributionType: LibOracleUniGeoDistribution.DistributionType.UNIFORM,
                oracleIsTickLower: true,
                oracleTickOffset: 0,
                nonOracleTick: TICK_SPACING * 10,
                alpha: 1.2e8
            });
            (uint256 density,,, bytes32 state, bool surge) = ldf.query({
                key: key,
                roundedTick: 0,
                twapTick: 0,
                spotPriceTick: 0,
                ldfParams: ldfParams,
                ldfState: bytes32(0)
            });

            assertTrue(density > 0, "Should return non-zero density (bond < stablecoin)");
            assertFalse(surge, "Should not surge on first initialization (bond < stablecoin)");
            assertTrue(state != bytes32(0), "Should return non-zero state (bond < stablecoin)");
        }

        // Test bond > stablecoin case
        {
            // Uniform [-10 * TICK_SPACING, 0]
            bytes32 ldfParams = ldf.encodeLdfParams({
                distributionType: LibOracleUniGeoDistribution.DistributionType.UNIFORM,
                oracleIsTickLower: false,
                oracleTickOffset: 0,
                nonOracleTick: TICK_SPACING * -10,
                alpha: 1.2e8
            });
            (uint256 densityReversed,,, bytes32 stateReversed, bool surgeReversed) = ldfReversed.query({
                key: key,
                roundedTick: TICK_SPACING * -10,
                twapTick: 0,
                spotPriceTick: 0,
                ldfParams: ldfParams,
                ldfState: bytes32(0)
            });

            assertTrue(densityReversed > 0, "Should return non-zero density (bond > stablecoin)");
            assertFalse(surgeReversed, "Should not surge on first initialization (bond > stablecoin)");
            assertTrue(stateReversed != bytes32(0), "Should return non-zero state (bond > stablecoin)");
        }
    }

    function test_shouldSurgeOnOraclePriceChange() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(bond)),
            currency1: Currency.wrap(address(stablecoin)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: hook
        });

        bytes32 ldfParams = _createDefaultParams();

        // Test bond < stablecoin case
        {
            oracle.setFloorPrice(1e18);
            (,,, bytes32 state1, bool surge1) = ldf.query({
                key: key,
                roundedTick: 0,
                twapTick: 0,
                spotPriceTick: 0,
                ldfParams: ldfParams,
                ldfState: bytes32(0)
            });
            assertFalse(surge1, "Should not surge on first query (bond < stablecoin)");

            oracle.setFloorPrice(1.1e18);
            (,,, bytes32 state2, bool surge2) = ldf.query({
                key: key,
                roundedTick: 0,
                twapTick: 0,
                spotPriceTick: 0,
                ldfParams: ldfParams,
                ldfState: state1
            });
            assertTrue(surge2, "Should surge on price change (bond < stablecoin)");
            assertTrue(state1 != state2, "State should change (bond < stablecoin)");

            (,,, bytes32 state3, bool surge3) = ldf.query({
                key: key,
                roundedTick: 0,
                twapTick: 0,
                spotPriceTick: 0,
                ldfParams: ldfParams,
                ldfState: state2
            });
            assertFalse(surge3, "Should not surge on second query (bond < stablecoin)");
            assertTrue(state2 == state3, "State should not change (bond < stablecoin)");
        }

        // Test bond > stablecoin case
        {
            oracle.setFloorPrice(1e18);
            (,,, bytes32 state1, bool surge1) = ldfReversed.query({
                key: key,
                roundedTick: 0,
                twapTick: 0,
                spotPriceTick: 0,
                ldfParams: ldfParams,
                ldfState: bytes32(0)
            });
            assertFalse(surge1, "Should not surge on first query (bond > stablecoin)");

            oracle.setFloorPrice(1.1e18);
            (,,, bytes32 state2, bool surge2) = ldfReversed.query({
                key: key,
                roundedTick: 0,
                twapTick: 0,
                spotPriceTick: 0,
                ldfParams: ldfParams,
                ldfState: state1
            });
            assertTrue(surge2, "Should surge on price change (bond > stablecoin)");
            assertTrue(state1 != state2, "State should change (bond > stablecoin)");

            (,,, bytes32 state3, bool surge3) = ldfReversed.query({
                key: key,
                roundedTick: 0,
                twapTick: 0,
                spotPriceTick: 0,
                ldfParams: ldfParams,
                ldfState: state2
            });
            assertFalse(surge3, "Should not surge on second query (bond > stablecoin)");
            assertTrue(state2 == state3, "State should not change (bond > stablecoin)");
        }
    }

    function test_shouldSurgeOnParamsUpdate() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(bond)),
            currency1: Currency.wrap(address(stablecoin)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: hook
        });

        bytes32 initialParams = ldf.encodeLdfParams({
            distributionType: LibOracleUniGeoDistribution.DistributionType.GEOMETRIC,
            oracleIsTickLower: true,
            oracleTickOffset: 0,
            nonOracleTick: TICK_SPACING * 10,
            alpha: 1.2e8
        });

        oracle.setFloorPrice(1e18);
        (,,, bytes32 state1,) = ldf.query({
            key: key,
            roundedTick: 0,
            twapTick: 0,
            spotPriceTick: 0,
            ldfParams: initialParams,
            ldfState: bytes32(0)
        });

        // Change width
        bytes32 newParams1 = ldf.encodeLdfParams({
            distributionType: LibOracleUniGeoDistribution.DistributionType.GEOMETRIC,
            oracleIsTickLower: true,
            oracleTickOffset: 0,
            nonOracleTick: TICK_SPACING * 20,
            alpha: 1.2e8
        });
        vm.prank(owner);
        ldf.setLdfParams(key, newParams1); // override params
        (,,,, bool surge1) = ldf.query({
            key: key,
            roundedTick: 0,
            twapTick: 0,
            spotPriceTick: 0,
            ldfParams: initialParams, // overriding params doesn't update immutable ldfParams
            ldfState: state1
        });
        assertTrue(surge1, "Should surge on width change");

        // Change alpha
        bytes32 newParams2 = ldf.encodeLdfParams({
            distributionType: LibOracleUniGeoDistribution.DistributionType.GEOMETRIC,
            oracleIsTickLower: true,
            oracleTickOffset: 0,
            nonOracleTick: TICK_SPACING * 20,
            alpha: 1.21e8
        });
        vm.prank(owner);
        ldf.setLdfParams(key, newParams2);
        (,,,, bool surge2) = ldf.query({
            key: key,
            roundedTick: 0,
            twapTick: 0,
            spotPriceTick: 0,
            ldfParams: initialParams,
            ldfState: state1
        });
        assertTrue(surge2, "Should surge on alpha change");

        // Change distribution type
        bytes32 newParams3 = ldf.encodeLdfParams({
            distributionType: LibOracleUniGeoDistribution.DistributionType.UNIFORM,
            oracleIsTickLower: true,
            oracleTickOffset: 0,
            nonOracleTick: TICK_SPACING * 20,
            alpha: 1.21e8
        });
        vm.prank(owner);
        ldf.setLdfParams(key, newParams3);
        (,,,, bool surge3) = ldf.query({
            key: key,
            roundedTick: 0,
            twapTick: 0,
            spotPriceTick: 0,
            ldfParams: initialParams,
            ldfState: state1
        });
        assertTrue(surge3, "Should surge on distribution type change");
    }

    function test_ldfMatchesBaseDistributions() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(bond)),
            currency1: Currency.wrap(address(stablecoin)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: hook
        });

        oracle.setFloorPrice(1e18);
        int24 oracleTick = 0; // since price is 1e18
        int24 nonOracleTick = TICK_SPACING * 10;
        uint256 totalLiquidity = Q96;

        int24 oracleTickOffset = -TICK_SPACING;
        int24 tickLower = oracleTick + oracleTickOffset;
        int24 tickUpper = nonOracleTick;
        int24 length = (tickUpper - tickLower) / TICK_SPACING;

        // Test UNIFORM distribution
        {
            bytes32 uniformParams = ldf.encodeLdfParams({
                distributionType: LibOracleUniGeoDistribution.DistributionType.UNIFORM,
                oracleIsTickLower: true,
                oracleTickOffset: int16(oracleTickOffset),
                nonOracleTick: nonOracleTick,
                alpha: 1.1e8
            });

            // override LDF params
            vm.prank(owner);
            ldf.setLdfParams(key, uniformParams);

            // Test query at several points
            int24[] memory testTicks = new int24[](3);
            testTicks[0] = TICK_SPACING * 2; // near lower bound
            testTicks[1] = TICK_SPACING * 5; // middle
            testTicks[2] = TICK_SPACING * 8; // near upper bound

            for (uint256 i = 0; i < testTicks.length; i++) {
                int24 testTick = testTicks[i];

                // Test query
                (uint256 actualDensity, uint256 actualCumAmount0, uint256 actualCumAmount1,,) = ldf.query({
                    key: key,
                    roundedTick: testTick,
                    twapTick: 0,
                    spotPriceTick: 0,
                    ldfParams: uniformParams,
                    ldfState: bytes32(0)
                });

                (uint256 expectedDensity, uint256 expectedCumAmount0, uint256 expectedCumAmount1) =
                    LibUniformDistribution.query(testTick, TICK_SPACING, tickLower, tickUpper);

                assertEq(actualDensity, expectedDensity, "Uniform density mismatch");
                assertEq(actualCumAmount0, expectedCumAmount0, "Uniform cumAmount0 mismatch");
                assertEq(actualCumAmount1, expectedCumAmount1, "Uniform cumAmount1 mismatch");

                // Test cumulativeAmount0 and cumulativeAmount1
                uint256 actualAmount0 = LibUniformDistribution.cumulativeAmount0(
                    testTick + TICK_SPACING,
                    totalLiquidity,
                    TICK_SPACING,
                    tickLower,
                    tickUpper,
                    false // not carpet
                );

                uint256 actualAmount1 = LibUniformDistribution.cumulativeAmount1(
                    testTick - TICK_SPACING,
                    totalLiquidity,
                    TICK_SPACING,
                    tickLower,
                    tickUpper,
                    false // not carpet
                );

                assertEq(actualAmount0, actualCumAmount0, "Uniform cumulativeAmount0 mismatch");
                assertEq(actualAmount1, actualCumAmount1, "Uniform cumulativeAmount1 mismatch");

                // Test inverseCumulativeAmount0 and inverseCumulativeAmount1
                // First test the library implementations
                (bool success0, int24 inverseTick0) = LibUniformDistribution.inverseCumulativeAmount0(
                    actualAmount0,
                    totalLiquidity,
                    TICK_SPACING,
                    tickLower,
                    tickUpper,
                    false // not carpet
                );

                (bool success1, int24 inverseTick1) = LibUniformDistribution.inverseCumulativeAmount1(
                    actualAmount1,
                    totalLiquidity,
                    TICK_SPACING,
                    tickLower,
                    tickUpper,
                    false // not carpet
                );

                assertTrue(success0, "Uniform inverseCumulativeAmount0 should succeed");
                assertTrue(success1, "Uniform inverseCumulativeAmount1 should succeed");

                // Now test LibOracleUniGeoDistribution's inverse functions
                (bool oracleSuccess0, int24 oracleInverseTick0) = LibOracleUniGeoDistribution.inverseCumulativeAmount0(
                    actualAmount0,
                    totalLiquidity,
                    TICK_SPACING,
                    tickLower,
                    tickUpper,
                    0, // alphaX96 (0 for uniform)
                    LibOracleUniGeoDistribution.DistributionType.UNIFORM
                );

                (bool oracleSuccess1, int24 oracleInverseTick1) = LibOracleUniGeoDistribution.inverseCumulativeAmount1(
                    actualAmount1,
                    totalLiquidity,
                    TICK_SPACING,
                    tickLower,
                    tickUpper,
                    0, // alphaX96 (0 for uniform)
                    LibOracleUniGeoDistribution.DistributionType.UNIFORM
                );

                // Compare results between library and LibOracleUniGeoDistribution
                assertEq(oracleSuccess0, success0, "Oracle and lib success0 should match");
                assertEq(oracleSuccess1, success1, "Oracle and lib success1 should match");
                assertEq(oracleInverseTick0, inverseTick0, "Oracle and lib inverseTick0 should match");
                assertEq(oracleInverseTick1, inverseTick1, "Oracle and lib inverseTick1 should match");
            }
        }

        // Test GEOMETRIC distribution
        {
            uint32 alpha = 1.2e8; // alpha = 1.2
            uint256 alphaX96 = uint256(alpha) * Q96 / 1e8;
            bytes32 geoParams = ldf.encodeLdfParams({
                distributionType: LibOracleUniGeoDistribution.DistributionType.GEOMETRIC,
                oracleIsTickLower: true,
                oracleTickOffset: int16(oracleTickOffset),
                nonOracleTick: nonOracleTick,
                alpha: alpha
            });

            // override LDF params
            vm.prank(owner);
            ldf.setLdfParams(key, geoParams);

            // Test at several points
            int24[] memory testTicks = new int24[](3);
            testTicks[0] = TICK_SPACING * 2; // near lower bound
            testTicks[1] = TICK_SPACING * 5; // middle
            testTicks[2] = TICK_SPACING * 8; // near upper bound

            for (uint256 i = 0; i < testTicks.length; i++) {
                int24 testTick = testTicks[i];

                // Test query
                (uint256 actualDensity, uint256 actualCumAmount0, uint256 actualCumAmount1,,) = ldf.query({
                    key: key,
                    roundedTick: testTick,
                    twapTick: 0,
                    spotPriceTick: 0,
                    ldfParams: geoParams,
                    ldfState: bytes32(0)
                });

                (uint256 expectedDensity, uint256 expectedCumAmount0, uint256 expectedCumAmount1) =
                    LibGeometricDistribution.query(testTick, TICK_SPACING, tickLower, length, alphaX96);

                assertEq(actualDensity, expectedDensity, "Geometric density mismatch");
                assertEq(actualCumAmount0, expectedCumAmount0, "Geometric cumAmount0 mismatch");
                assertEq(actualCumAmount1, expectedCumAmount1, "Geometric cumAmount1 mismatch");

                // Test cumulativeAmount0 and cumulativeAmount1
                uint256 actualAmount0 = LibGeometricDistribution.cumulativeAmount0(
                    testTick + TICK_SPACING, totalLiquidity, TICK_SPACING, tickLower, length, alphaX96
                );

                uint256 actualAmount1 = LibGeometricDistribution.cumulativeAmount1(
                    testTick - TICK_SPACING, totalLiquidity, TICK_SPACING, tickLower, length, alphaX96
                );

                assertEq(actualAmount0, actualCumAmount0, "Geometric cumulativeAmount0 mismatch");
                assertEq(actualAmount1, actualCumAmount1, "Geometric cumulativeAmount1 mismatch");

                // Test inverseCumulativeAmount0 and inverseCumulativeAmount1
                // First test the library implementations
                (bool success0, int24 inverseTick0) = LibGeometricDistribution.inverseCumulativeAmount0(
                    actualAmount0, totalLiquidity, TICK_SPACING, tickLower, length, alphaX96
                );

                (bool success1, int24 inverseTick1) = LibGeometricDistribution.inverseCumulativeAmount1(
                    actualAmount1, totalLiquidity, TICK_SPACING, tickLower, length, alphaX96
                );

                assertTrue(success0, "Geometric inverseCumulativeAmount0 should succeed");
                assertTrue(success1, "Geometric inverseCumulativeAmount1 should succeed");

                // Now test LibOracleUniGeoDistribution's inverse functions
                (bool oracleSuccess0, int24 oracleInverseTick0) = LibOracleUniGeoDistribution.inverseCumulativeAmount0(
                    actualAmount0,
                    totalLiquidity,
                    TICK_SPACING,
                    tickLower,
                    tickUpper,
                    alphaX96,
                    LibOracleUniGeoDistribution.DistributionType.GEOMETRIC
                );

                (bool oracleSuccess1, int24 oracleInverseTick1) = LibOracleUniGeoDistribution.inverseCumulativeAmount1(
                    actualAmount1,
                    totalLiquidity,
                    TICK_SPACING,
                    tickLower,
                    tickUpper,
                    alphaX96,
                    LibOracleUniGeoDistribution.DistributionType.GEOMETRIC
                );

                // Compare results between library and LibOracleUniGeoDistribution
                assertEq(oracleSuccess0, success0, "Oracle and lib success0 should match");
                assertEq(oracleSuccess1, success1, "Oracle and lib success1 should match");
                assertEq(oracleInverseTick0, inverseTick0, "Oracle and lib inverseTick0 should match");
                assertEq(oracleInverseTick1, inverseTick1, "Oracle and lib inverseTick1 should match");
            }
        }

        // Test zero density outside bounds remains unchanged
        {
            bytes32[] memory paramsToTest = new bytes32[](2);
            paramsToTest[0] = ldf.encodeLdfParams({
                distributionType: LibOracleUniGeoDistribution.DistributionType.UNIFORM,
                oracleIsTickLower: true,
                oracleTickOffset: 0,
                nonOracleTick: TICK_SPACING * 10,
                alpha: 0.9e8
            });
            paramsToTest[1] = ldf.encodeLdfParams({
                distributionType: LibOracleUniGeoDistribution.DistributionType.GEOMETRIC,
                oracleIsTickLower: true,
                oracleTickOffset: 0,
                nonOracleTick: TICK_SPACING * 10,
                alpha: 1.2e8
            });

            for (uint256 i = 0; i < paramsToTest.length; i++) {
                // override LDF params
                vm.prank(owner);
                ldf.setLdfParams(key, paramsToTest[i]);

                // Test below lower bound
                (uint256 belowDensity,,,,) = ldf.query({
                    key: key,
                    roundedTick: -TICK_SPACING,
                    twapTick: 0,
                    spotPriceTick: 0,
                    ldfParams: paramsToTest[i],
                    ldfState: bytes32(0)
                });

                // Test above upper bound
                (uint256 aboveDensity,,,,) = ldf.query({
                    key: key,
                    roundedTick: TICK_SPACING * 11,
                    twapTick: 0,
                    spotPriceTick: 0,
                    ldfParams: paramsToTest[i],
                    ldfState: bytes32(0)
                });

                assertEq(belowDensity, 0, "Density should be zero below lower bound");
                assertEq(aboveDensity, 0, "Density should be zero above upper bound");
            }
        }
    }

    function test_invalidParams() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(bond)),
            currency1: Currency.wrap(address(stablecoin)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: hook
        });

        // initialize floor price
        oracle.setFloorPrice(1e18);

        // Test invalid alpha
        bytes32 invalidAlpha = ldf.encodeLdfParams({
            distributionType: LibOracleUniGeoDistribution.DistributionType.GEOMETRIC,
            oracleIsTickLower: true,
            oracleTickOffset: 0,
            nonOracleTick: TICK_SPACING * 10,
            alpha: 1 // Invalid: alpha too small
        });
        assertFalse(
            ldf.isValidParams(key, 0, invalidAlpha, LDFType.DYNAMIC_AND_STATEFUL), "Should reject invalid alpha"
        );

        // Test invalid distribution type
        bytes32 defaultParams = _createDefaultParams();
        bytes32 invalidType = bytes32(bytes2(0x00FF)) | defaultParams; // Invalid distribution type
        assertFalse(
            ldf.isValidParams(key, 0, invalidType, LDFType.DYNAMIC_AND_STATEFUL),
            "Should reject invalid distribution type"
        );

        // Test invalid ldfType
        assertFalse(ldf.isValidParams(key, 0, defaultParams, LDFType.STATIC), "Should reject invalid ldfType");
    }

    struct TestCase {
        uint256 price;
        int24 tickSpacing;
        int24 expectedRick;
    }

    function test_floorPriceToRick() public {
        // Test cases with price, tickSpacing, and expected rick

        TestCase[] memory cases = new TestCase[](6);

        // Price 1.0 (tick 0) with different spacings
        cases[0] = TestCase({price: 1e18, tickSpacing: 10, expectedRick: 0});

        // Price 2.0 (tick 6932) with spacing 100
        // Should round down to 6900
        cases[1] = TestCase({price: 2e18, tickSpacing: 100, expectedRick: 6900});

        // Price 0.5 (tick -6932) with spacing 60
        // Should round down to -6960
        cases[2] = TestCase({price: 0.5e18, tickSpacing: 60, expectedRick: -6960});

        // Price 1.0001^53 with spacing 10
        // Tick 53 should round down to 50
        cases[3] = TestCase({price: 1.0053138035e18, tickSpacing: 10, expectedRick: 50});

        // Price that results in tick -23 with spacing 20
        // Should round down to -40
        cases[4] = TestCase({price: 0.9977027577e18, tickSpacing: 20, expectedRick: -40});

        // Price near tick boundary with spacing 100
        // Should round down to next multiple of tickSpacing
        cases[5] = TestCase({
            price: 1.00199e18,
            tickSpacing: 100,
            expectedRick: 0 // rounds down from ~20 to 0
        });

        for (uint256 i = 0; i < cases.length; i++) {
            TestCase memory tc = cases[i];
            oracle.setFloorPrice(tc.price);

            int24 actualRick = ldf.floorPriceToRick(tc.price, tc.tickSpacing);

            assertEq(
                actualRick,
                tc.expectedRick,
                string.concat(
                    "Rick conversion failed for price: ",
                    vm.toString(tc.price),
                    " with tickSpacing: ",
                    vm.toString(uint256(uint24(tc.tickSpacing)))
                )
            );

            // Verify rick is divisible by tickSpacing
            assertEq(actualRick % tc.tickSpacing, 0, "Rick must be divisible by tickSpacing");

            // Verify rick is within valid range
            assertTrue(actualRick >= TickMath.MIN_TICK && actualRick <= TickMath.MAX_TICK, "Rick out of bounds");
        }

        // Test with reversed token order (bondLtStablecoin = false)
        oracle.setFloorPrice(2e18);
        int24 normalRick = ldf.floorPriceToRick(2e18, 100);
        int24 reversedRick = ldfReversed.floorPriceToRick(2e18, 100);
        assertEq(reversedRick, -normalRick - 100, "Reversed token order should negate the rick");
    }

    function test_setLdfParams_onlyOwner() public {
        bytes4 selector = bytes4(0x82b42900); // Unauthorized() selector
        address nonOwner = address(0xdead);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(bond)),
            currency1: Currency.wrap(address(stablecoin)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: hook
        });

        // initialize floor price
        oracle.setFloorPrice(1e18);

        // Test first version of setLdfParams (with individual parameters)
        vm.startPrank(nonOwner);
        vm.expectRevert(selector); // Unauthorized()
        ldf.setLdfParams({
            key: key,
            distributionType: LibOracleUniGeoDistribution.DistributionType.GEOMETRIC,
            oracleIsTickLower: true,
            oracleTickOffset: 0,
            nonOracleTick: TICK_SPACING * 20,
            alpha: 1.2e8
        });
        vm.stopPrank();

        // Should work with owner
        vm.prank(owner);
        ldf.setLdfParams({
            key: key,
            distributionType: LibOracleUniGeoDistribution.DistributionType.GEOMETRIC,
            oracleIsTickLower: true,
            oracleTickOffset: 0,
            nonOracleTick: TICK_SPACING * 20,
            alpha: 1.2e8
        });

        // Test second version of setLdfParams (with encoded params)
        bytes32 params = ldf.encodeLdfParams({
            distributionType: LibOracleUniGeoDistribution.DistributionType.UNIFORM,
            oracleIsTickLower: true,
            oracleTickOffset: 0,
            nonOracleTick: TICK_SPACING * 10,
            alpha: 1.2e8
        });

        vm.startPrank(nonOwner);
        vm.expectRevert(selector); // Unauthorized()
        ldf.setLdfParams(key, params);
        vm.stopPrank();

        // Should work with owner
        vm.prank(owner);
        ldf.setLdfParams(key, params);

        // Verify the params were actually set by the owner
        PoolId id = key.toId();
        (bool overridden, bytes12 storedParams) = ldf.ldfParamsOverride(id);
        assertTrue(overridden, "Params should be overridden");
        assertEq(bytes32(storedParams), params, "Params should be stored correctly");
    }

    /// -----------------------------------------------------------------------
    /// Internal helpers
    /// -----------------------------------------------------------------------

    function _createDefaultParams() internal view returns (bytes32) {
        return ldf.encodeLdfParams({
            distributionType: LibOracleUniGeoDistribution.DistributionType.UNIFORM,
            oracleIsTickLower: true,
            oracleTickOffset: 0,
            nonOracleTick: TICK_SPACING * 10,
            alpha: 1.2e8
        });
    }
}
