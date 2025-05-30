// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import "./BaseTest.sol";
import {BunniStateLibrary} from "../src/lib/BunniStateLibrary.sol";

contract BunniStateLibraryTest is BaseTest {
    using BunniStateLibrary for *;

    function test_getVaultSharePricesAtLastSwap() public {
        // deploy pool
        (, PoolKey memory key) =
            _deployPoolAndInitLiquidity(Currency.wrap(address(token0)), Currency.wrap(address(token1)), vault0, vault1);
        PoolId id = key.toId();

        // check that the share prices are not initialized
        (bool initialized, uint120 sharePrice0, uint120 sharePrice1) = bunniHook.getVaultSharePricesAtLastSwap(id);
        assertEq(initialized, false, "share prices should not be initialized");
        assertEq(sharePrice0, 0, "share price 0 should be 0");
        assertEq(sharePrice1, 0, "share price 1 should be 0");

        // make a swap
        _mint(key.currency0, address(this), 1 ether);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(1 ether),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        _swap(key, params, 0, "");

        // check that the share prices are initialized
        (initialized, sharePrice0, sharePrice1) = bunniHook.getVaultSharePricesAtLastSwap(id);
        assertEq(initialized, true, "share prices should be initialized");
        assertApproxEqAbs(sharePrice0, 2e18, 10, "share price 0 should be 2e18");
        assertApproxEqAbs(sharePrice1, 2e18, 10, "share price 1 should be 2e18");

        // mint tokens to vault0 and vault1 to update the share prices
        // initial price is 2e18, so after minting vault0's price becomes 4e18 and vault1's price becomes 6e18
        _mint(key.currency0, address(vault0), token0.balanceOf(address(vault0)));
        _mint(key.currency1, address(vault1), token1.balanceOf(address(vault1)) * 2);

        // make a swap
        _mint(key.currency0, address(this), 1 ether);
        _swap(key, params, 0, "");

        // check that the share prices are updated
        (initialized, sharePrice0, sharePrice1) = bunniHook.getVaultSharePricesAtLastSwap(id);
        assertEq(initialized, true, "share prices should be initialized");
        assertApproxEqAbs(sharePrice0, 4e18, 10, "share price 0 should be 4e18");
        assertApproxEqAbs(sharePrice1, 6e18, 10, "share price 1 should be 6e18");
    }
}
