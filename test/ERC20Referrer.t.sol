// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import "forge-std/Test.sol";

import "../src/base/Constants.sol";
import "./mocks/ERC20ReferrerMock.sol";
import "./mocks/ERC20UnlockerMock.sol";
import {IERC20Lockable} from "../src/interfaces/IERC20Lockable.sol";

contract ERC20ReferrerTest is Test {
    ERC20ReferrerMock token;
    ERC20UnlockerMock unlocker;
    address bob = makeAddr("bob");
    address eve = makeAddr("eve");

    function setUp() public {
        token = new ERC20ReferrerMock();
        unlocker = new ERC20UnlockerMock(token);
    }

    function test_mint_single(uint256 amount, address referrer) external {
        amount = bound(amount, 0, type(uint232).max);

        // initial score of referrer is 0
        assertEq(token.scoreOf(referrer), 0, "initial score not 0");

        // mint `amount` tokens to `bob` with referrer `referrer`
        token.mint(bob, amount, referrer);

        // referrer of `bob` is `referrer`
        assertEq(token.referrerOf(bob), referrer, "referrer incorrect");

        // balance of `bob` is `amount`
        assertEq(token.balanceOf(bob), amount, "balance not equal to amount");

        // score of `referrer` is `amount`
        assertEq(token.scoreOf(referrer), amount, "score not equal to amount");

        // total supply is `amount`
        assertEq(token.totalSupply(), amount, "total supply not equal to amount");
    }

    function test_mint_double_sameReferrer(uint256 amount0, uint256 amount1, address referrer) external {
        amount0 = bound(amount0, 0, type(uint232).max);
        amount1 = bound(amount1, 0, type(uint232).max - amount0);

        // initial score of referrer is 0
        assertEq(token.scoreOf(referrer), 0, "initial score not 0");

        // mint `amount0` tokens to `bob` with referrer `referrer`
        token.mint(bob, amount0, referrer);

        // mint `amount1` tokens to `bob` with referrer `referrer`
        token.mint(bob, amount1, referrer);

        // referrer of `bob` is `referrer`
        assertEq(token.referrerOf(bob), referrer, "bob referrer incorrect");

        // balance of `bob` is `amount0 + amount1`
        assertEq(token.balanceOf(bob), amount0 + amount1, "bob balance not equal to amount0 + amount1");

        // score of `referrer` is `amount0 + amount1`
        assertEq(token.scoreOf(referrer), amount0 + amount1, "referrer score incorrect");

        // total supply is `amount0 + amount1`
        assertEq(token.totalSupply(), amount0 + amount1, "total supply not equal to amount0 + amount1");
    }

    function test_mint_double_differentReferrer(uint256 amount0, uint256 amount1, address referrer0, address referrer1)
        external
    {
        vm.assume(referrer0 != referrer1 && referrer0 != address(0) && referrer1 != address(0));
        amount0 = bound(amount0, 0, type(uint232).max);
        amount1 = bound(amount1, 0, type(uint232).max - amount0);

        // initial score of referrer0 is 0
        assertEq(token.scoreOf(referrer0), 0, "initial score not 0");

        // initial score of referrer1 is 0
        assertEq(token.scoreOf(referrer1), 0, "initial score not 0");

        // mint `amount0` tokens to `bob` with referrer `referrer0`
        token.mint(bob, amount0, referrer0);

        // mint `amount1` tokens to `bob` with referrer `referrer1`
        token.mint(bob, amount1, referrer1);

        // referrer of `bob` is `referrer0` since referrer is immutable once set
        assertEq(token.referrerOf(bob), referrer0, "bob referrer incorrect");

        // balance of `bob` is `amount0 + amount1`
        assertEq(token.balanceOf(bob), amount0 + amount1, "bob balance not equal to amount0 + amount1");

        // score of `referrer0` is `amount0 + amount1`
        assertEq(token.scoreOf(referrer0), amount0 + amount1, "referrer0 score incorrect");

        // score of `referrer1` is `0`
        assertEq(token.scoreOf(referrer1), 0, "referrer1 score incorrect");

        // total supply is `amount0 + amount1`
        assertEq(token.totalSupply(), amount0 + amount1, "total supply not equal to amount0 + amount1");
    }

    function test_mint_twoAccounts(uint256 amountBob, uint256 amountEve, address referrerBob, address referrerEve)
        external
    {
        amountBob = bound(amountBob, 0, type(uint232).max);
        amountEve = bound(amountEve, 0, type(uint232).max);

        // initial score of referrer is 0
        assertEq(token.scoreOf(referrerBob), 0, "initial bob referrer score not 0");
        assertEq(token.scoreOf(referrerEve), 0, "initial eve referrer score not 0");

        // mint `amountBob` tokens to `bob` with referrer `referrerBob`
        token.mint(bob, amountBob, referrerBob);

        // mint `amountEve` tokens to `eve` with referrer `referrerEve`
        token.mint(eve, amountEve, referrerEve);

        // referrer of `bob` is `referrerBob`
        assertEq(token.referrerOf(bob), referrerBob, "bob referrer incorrect");

        // referrer of `eve` is `referrerEve`
        assertEq(token.referrerOf(eve), referrerEve, "eve referrer incorrect");

        // balance of `bob` is `amountBob`
        assertEq(token.balanceOf(bob), amountBob, "bob balance not equal to amountBob");

        // balance of `eve` is `amountEve`
        assertEq(token.balanceOf(eve), amountEve, "eve balance not equal to amountEve");

        // score of `referrerBob` is `amountBob` or `amountBob + amountEve` if `referrerBob == referrerEve`
        assertEq(
            token.scoreOf(referrerBob),
            referrerBob == referrerEve ? amountBob + amountEve : amountBob,
            "bob referrer score incorrect"
        );

        // score of `referrerEve` is `amountEve` or `amountBob + amountEve` if `referrerBob == referrerEve`
        assertEq(
            token.scoreOf(referrerEve),
            referrerBob == referrerEve ? amountBob + amountEve : amountEve,
            "eve referrer score incorrect"
        );

        // total supply is `amountBob + amountEve`
        assertEq(token.totalSupply(), amountBob + amountEve, "total supply not equal to amountBob + amountEve");
    }

    function test_transfer_sameAccount(uint256 mintAmount, uint256 amount, address referrer) external {
        mintAmount = bound(mintAmount, 0, type(uint232).max);
        amount = bound(amount, 0, mintAmount);

        // mint `mintAmount` tokens to `bob` with referrer `referrer`
        token.mint(bob, mintAmount, referrer);

        // transfer `amount` tokens from `bob` to `bob`
        vm.prank(bob);
        token.transfer(bob, amount);

        // referrer of `bob` is `referrer`
        assertEq(token.referrerOf(bob), referrer, "referrer incorrect");

        // balance of `bob` is `mintAmount`
        assertEq(token.balanceOf(bob), mintAmount, "balance not equal to mintAmount");

        // score of `referrer` is `mintAmount`
        assertEq(token.scoreOf(referrer), mintAmount, "score not equal to mintAmount");

        // total supply is `mintAmount`
        assertEq(token.totalSupply(), mintAmount, "total supply not equal to mintAmount");
    }

    function test_transfer_differentAccountSameReferrer(uint256 mintAmount, uint256 amount, address referrer)
        external
    {
        mintAmount = bound(mintAmount, 0, type(uint232).max / 2);
        amount = bound(amount, 0, mintAmount);

        // mint `mintAmount` tokens to `bob` with referrer `referrer`
        token.mint(bob, mintAmount, referrer);

        // mint `mintAmount` tokens to `eve` with referrer `referrer`
        token.mint(eve, mintAmount, referrer);

        // transfer `amount` tokens from `bob` to `eve`
        vm.prank(bob);
        token.transfer(eve, amount);

        // referrer of `bob` is `referrer`
        assertEq(token.referrerOf(bob), referrer, "bob referrer incorrect");

        // referrer of `eve` is `referrer`
        assertEq(token.referrerOf(eve), referrer, "eve referrer incorrect");

        // balance of `bob` is `mintAmount - amount`
        assertEq(token.balanceOf(bob), mintAmount - amount, "bob balance incorrect");

        // balance of `eve` is `mintAmount + amount`
        assertEq(token.balanceOf(eve), mintAmount + amount, "eve balance incorrect");

        // score of `referrer` is `2 * mintAmount`
        assertEq(token.scoreOf(referrer), 2 * mintAmount, "referrer score incorrect");

        // total supply is `2 * mintAmount`
        assertEq(token.totalSupply(), 2 * mintAmount, "total supply incorrect");
    }

    function test_transfer_differentAccountDifferentReferrer(
        uint256 mintAmount,
        uint256 amount,
        address referrer0,
        address referrer1
    ) external {
        mintAmount = bound(mintAmount, 0, type(uint232).max / 2);
        amount = bound(amount, 0, mintAmount);
        vm.assume(referrer0 != referrer1);

        // mint `mintAmount` tokens to `bob` with referrer `referrer0`
        token.mint(bob, mintAmount, referrer0);

        // mint `mintAmount` tokens to `eve` with referrer `referrer1`
        token.mint(eve, mintAmount, referrer1);

        // transfer `amount` tokens from `bob` to `eve`
        vm.prank(bob);
        token.transfer(eve, amount);

        // referrer of `bob` is `referrer0`
        assertEq(token.referrerOf(bob), referrer0, "bob referrer incorrect");

        // referrer of `eve` is `referrer1`
        assertEq(token.referrerOf(eve), referrer1, "eve referrer incorrect");

        // balance of `bob` is `mintAmount - amount`
        assertEq(token.balanceOf(bob), mintAmount - amount, "bob balance incorrect");

        // balance of `eve` is `mintAmount + amount`
        assertEq(token.balanceOf(eve), mintAmount + amount, "eve balance incorrect");

        // score of `referrer0` is `mintAmount - amount`
        assertEq(token.scoreOf(referrer0), mintAmount - amount, "referrer0 score incorrect");

        // score of `referrer1` is `mintAmount + amount`
        assertEq(token.scoreOf(referrer1), mintAmount + amount, "referrer1 score incorrect");

        // total supply is `2 * mintAmount`
        assertEq(token.totalSupply(), 2 * mintAmount, "total supply incorrect");
    }

    function test_transferFrom_sameAccount(uint256 mintAmount, uint256 amount, address referrer) external {
        mintAmount = bound(mintAmount, 0, type(uint232).max);
        amount = bound(amount, 0, mintAmount);

        // mint `mintAmount` tokens to `bob` with referrer `referrer`
        token.mint(bob, mintAmount, referrer);

        // approve `this` to transfer `amount` tokens
        vm.prank(bob);
        token.approve(address(this), amount);

        // transfer `amount` tokens from `bob` to `bob`
        token.transferFrom(bob, bob, amount);

        // referrer of `bob` is `referrer`
        assertEq(token.referrerOf(bob), referrer, "referrer incorrect");

        // balance of `bob` is `mintAmount`
        assertEq(token.balanceOf(bob), mintAmount, "balance not equal to mintAmount");

        // score of `referrer` is `mintAmount`
        assertEq(token.scoreOf(referrer), mintAmount, "score not equal to mintAmount");

        // total supply is `mintAmount`
        assertEq(token.totalSupply(), mintAmount, "total supply not equal to mintAmount");
    }

    function test_transferFrom_differentAccountSameReferrer(uint256 mintAmount, uint256 amount, address referrer)
        external
    {
        mintAmount = bound(mintAmount, 0, type(uint232).max / 2);
        amount = bound(amount, 0, mintAmount);

        // mint `mintAmount` tokens to `bob` with referrer `referrer`
        token.mint(bob, mintAmount, referrer);

        // mint `mintAmount` tokens to `eve` with referrer `referrer`
        token.mint(eve, mintAmount, referrer);

        // approve `this` to transfer `amount` tokens
        vm.prank(bob);
        token.approve(address(this), amount);

        // transfer `amount` tokens from `bob` to `eve`
        token.transferFrom(bob, eve, amount);

        // referrer of `bob` is `referrer`
        assertEq(token.referrerOf(bob), referrer, "bob referrer incorrect");

        // referrer of `eve` is `referrer`
        assertEq(token.referrerOf(eve), referrer, "eve referrer incorrect");

        // balance of `bob` is `mintAmount - amount`
        assertEq(token.balanceOf(bob), mintAmount - amount, "bob balance incorrect");

        // balance of `eve` is `mintAmount + amount`
        assertEq(token.balanceOf(eve), mintAmount + amount, "eve balance incorrect");

        // score of `referrer` is `2 * mintAmount`
        assertEq(token.scoreOf(referrer), 2 * mintAmount, "referrer score incorrect");

        // total supply is `2 * mintAmount`
        assertEq(token.totalSupply(), 2 * mintAmount, "total supply incorrect");
    }

    function test_transferFrom_differentAccountDifferentReferrer(
        uint256 mintAmount,
        uint256 amount,
        address referrer0,
        address referrer1
    ) external {
        mintAmount = bound(mintAmount, 0, type(uint232).max / 2);
        amount = bound(amount, 0, mintAmount);
        vm.assume(referrer0 != referrer1);

        // mint `mintAmount` tokens to `bob` with referrer `referrer0`
        token.mint(bob, mintAmount, referrer0);

        // mint `mintAmount` tokens to `eve` with referrer `referrer1`
        token.mint(eve, mintAmount, referrer1);

        // approve `this` to transfer `amount` tokens
        vm.prank(bob);
        token.approve(address(this), amount);

        // transfer `amount` tokens from `bob` to `eve`
        token.transferFrom(bob, eve, amount);

        // referrer of `bob` is `referrer0`
        assertEq(token.referrerOf(bob), referrer0, "bob referrer incorrect");

        // referrer of `eve` is `referrer1`
        assertEq(token.referrerOf(eve), referrer1, "eve referrer incorrect");

        // balance of `bob` is `mintAmount - amount`
        assertEq(token.balanceOf(bob), mintAmount - amount, "bob balance incorrect");

        // balance of `eve` is `mintAmount + amount`
        assertEq(token.balanceOf(eve), mintAmount + amount, "eve balance incorrect");

        // score of `referrer0` is `mintAmount - amount`
        assertEq(token.scoreOf(referrer0), mintAmount - amount, "referrer0 score incorrect");

        // score of `referrer1` is `mintAmount + amount`
        assertEq(token.scoreOf(referrer1), mintAmount + amount, "referrer1 score incorrect");

        // total supply is `2 * mintAmount`
        assertEq(token.totalSupply(), 2 * mintAmount, "total supply incorrect");
    }

    function test_burn_single(uint256 mintAmount, uint256 burnAmount, address referrer) external {
        mintAmount = bound(mintAmount, 0, type(uint232).max);
        burnAmount = bound(burnAmount, 0, mintAmount);

        // mint `mintAmount` tokens to `bob` with referrer `referrer`
        token.mint(bob, mintAmount, referrer);

        // burn `burnAmount` tokens from `bob`
        vm.prank(bob);
        token.burn(burnAmount);

        // referrer of `bob` is `referrer`
        assertEq(token.referrerOf(bob), referrer, "referrer incorrect");

        // balance of `bob` is `mintAmount - burnAmount`
        assertEq(token.balanceOf(bob), mintAmount - burnAmount, "balance incorrect");

        // score of `referrer` is `mintAmount - burnAmount`
        assertEq(token.scoreOf(referrer), mintAmount - burnAmount, "score incorrect");

        // total supply is `mintAmount - burnAmount`
        assertEq(token.totalSupply(), mintAmount - burnAmount, "total supply incorrect");
    }

    function test_burn_double(uint256 mintAmount, uint256 burnAmount0, uint256 burnAmount1, address referrer)
        external
    {
        mintAmount = bound(mintAmount, 0, type(uint232).max);
        burnAmount0 = bound(burnAmount0, 0, mintAmount);
        burnAmount1 = bound(burnAmount1, 0, mintAmount - burnAmount0);

        // mint `mintAmount` tokens to `bob` with referrer `referrer`
        token.mint(bob, mintAmount, referrer);

        // burn `burnAmount0` tokens from `bob`
        vm.prank(bob);
        token.burn(burnAmount0);

        // burn `burnAmount1` tokens from `bob`
        vm.prank(bob);
        token.burn(burnAmount1);

        // referrer of `bob` is `referrer`
        assertEq(token.referrerOf(bob), referrer, "referrer incorrect");

        // balance of `bob` is `mintAmount - burnAmount0 - burnAmount1`
        assertEq(token.balanceOf(bob), mintAmount - burnAmount0 - burnAmount1, "balance incorrect");

        // score of `referrer` is `mintAmount - burnAmount0 - burnAmount1`
        assertEq(token.scoreOf(referrer), mintAmount - burnAmount0 - burnAmount1, "score incorrect");

        // total supply is `mintAmount - burnAmount0 - burnAmount1`
        assertEq(token.totalSupply(), mintAmount - burnAmount0 - burnAmount1, "total supply incorrect");
    }

    function test_burn_twoAccounts(
        uint256 mintAmountBob,
        uint256 mintAmountEve,
        uint256 burnAmountBob,
        uint256 burnAmountEve,
        address referrerBob,
        address referrerEve
    ) external {
        mintAmountBob = bound(mintAmountBob, 0, type(uint232).max);
        mintAmountEve = bound(mintAmountEve, 0, type(uint232).max);
        burnAmountBob = bound(burnAmountBob, 0, mintAmountBob);
        burnAmountEve = bound(burnAmountEve, 0, mintAmountEve);

        // mint `mintAmountBob` tokens to `bob` with referrer `referrerBob`
        token.mint(bob, mintAmountBob, referrerBob);

        // mint `mintAmountEve` tokens to `eve` with referrer `referrerEve`
        token.mint(eve, mintAmountEve, referrerEve);

        // burn `burnAmountBob` tokens from `bob`
        vm.prank(bob);
        token.burn(burnAmountBob);

        // burn `burnAmountEve` tokens from `eve`
        vm.prank(eve);
        token.burn(burnAmountEve);

        // referrer of `bob` is `referrerBob`
        assertEq(token.referrerOf(bob), referrerBob, "bob referrer incorrect");

        // referrer of `eve` is `referrerEve`
        assertEq(token.referrerOf(eve), referrerEve, "eve referrer incorrect");

        // balance of `bob` is `mintAmountBob - burnAmountBob`
        assertEq(token.balanceOf(bob), mintAmountBob - burnAmountBob, "bob balance incorrect");

        // balance of `eve` is `mintAmountEve - burnAmountEve`
        assertEq(token.balanceOf(eve), mintAmountEve - burnAmountEve, "eve balance incorrect");

        // score of `referrerBob` is `mintAmountBob - burnAmountBob` if `referrerBob != referrerEve`
        // and `mintAmountBob - burnAmountBob + mintAmountEve - burnAmountEve` if `referrerBob == referrerEve`
        assertEq(
            token.scoreOf(referrerBob),
            referrerBob == referrerEve
                ? mintAmountBob - burnAmountBob + mintAmountEve - burnAmountEve
                : mintAmountBob - burnAmountBob,
            "bob referrer score incorrect"
        );

        // score of `referrerEve` is `mintAmountEve - burnAmountEve` if `referrerBob != referrerEve`
        // and `mintAmountBob - burnAmountBob + mintAmountEve - burnAmountEve` if `referrerBob == referrerEve`
        assertEq(
            token.scoreOf(referrerEve),
            referrerBob == referrerEve
                ? mintAmountBob - burnAmountBob + mintAmountEve - burnAmountEve
                : mintAmountEve - burnAmountEve,
            "eve referrer score incorrect"
        );

        // total supply is `mintAmountBob - burnAmountBob + mintAmountEve - burnAmountEve`
        assertEq(
            token.totalSupply(), mintAmountBob - burnAmountBob + mintAmountEve - burnAmountEve, "total supply incorrect"
        );
    }

    function test_lockable_lock(uint256 amount, address referrer, bytes calldata data) external {
        amount = bound(amount, 0, type(uint232).max);

        // mint `amount` tokens to `bob` with referrer `referrer`
        token.mint(bob, amount, referrer);

        // lock account as `bob`
        vm.prank(bob);
        token.lock(unlocker, data);

        // check isLocked
        assertTrue(token.isLocked(bob), "isLocked returned false");

        // check unlocker
        assertEq(address(token.unlockerOf(bob)), address(unlocker), "unlocker incorrect");

        // check balance
        assertEq(token.balanceOf(bob), amount, "balance incorrect");

        // check referrer
        assertEq(token.referrerOf(bob), referrer, "referrer incorrect");

        vm.startPrank(bob);

        // transfer from `bob` should fail
        vm.expectRevert(IERC20Lockable.AccountLocked.selector);
        token.transfer(eve, amount);

        // calling lock again should fail
        vm.expectRevert(IERC20Lockable.AlreadyLocked.selector);
        token.lock(unlocker, data);

        // calling unlock() directly should fail
        vm.expectRevert(IERC20Lockable.NotUnlocker.selector);
        token.unlock(bob);

        // burning should fail
        vm.expectRevert(IERC20Lockable.AccountLocked.selector);
        token.burn(amount);

        vm.stopPrank();

        // unlocker should have up to date info
        assertEq(unlocker.lockedBalances(bob), amount, "locked balance incorrect");
        assertEq(keccak256(unlocker.lockDatas(bob)), keccak256(data), "lock data incorrect");
    }

    function test_lockable_transferToLockedAccount(uint256 amount, address referrer, bytes calldata data) external {
        amount = bound(amount, 0, type(uint232).max / 2);

        // mint `amount` tokens to `bob` with referrer `referrer`
        token.mint(bob, amount, referrer);

        // lock account as `eve`
        vm.prank(eve);
        token.lock(unlocker, data);

        // transfer to locked account should succeed
        vm.prank(bob);
        token.transfer(eve, amount);

        // minting to locked account should succeed
        token.mint(eve, amount, referrer);

        // unlocker should have up to date info
        assertEq(unlocker.lockedBalances(eve), amount * 2, "locked balance incorrect");
        assertEq(keccak256(unlocker.lockDatas(eve)), keccak256(data), "lock data incorrect");

        // check balance
        assertEq(token.balanceOf(eve), amount * 2, "balance incorrect");

        // check referrer
        assertEq(token.referrerOf(eve), referrer, "referrer incorrect");

        // check isLocked
        assertTrue(token.isLocked(eve), "isLocked returned false");
    }

    function test_lockable_unlock(uint256 amount, address referrer, bytes calldata data) external {
        amount = bound(amount, 0, type(uint232).max);

        // mint `amount` tokens to `bob` with referrer `referrer`
        token.mint(bob, amount, referrer);

        // lock account as `bob`
        vm.prank(bob);
        token.lock(unlocker, data);

        // unlock `bob`
        unlocker.unlock(bob);

        // check isLocked
        assertFalse(token.isLocked(bob), "isLocked returned true after unlocking");

        // check balance
        assertEq(token.balanceOf(bob), amount, "balance incorrect");

        // check referrer
        assertEq(token.referrerOf(bob), referrer, "referrer incorrect");

        // transfer from `bob` should succeed
        vm.prank(bob);
        token.transfer(eve, amount / 2);
        assertEq(token.balanceOf(bob), amount - amount / 2, "balance incorrect after sending tokens");
        assertEq(token.balanceOf(eve), amount / 2, "balance incorrect after receiving tokens");

        // burning from `bob` should succeed
        vm.prank(bob);
        token.burn(amount - amount / 2);
        assertEq(token.balanceOf(bob), 0, "balance incorrect after burning");

        // calling unlock() again should fail
        vm.expectRevert(IERC20Lockable.AlreadyUnlocked.selector);
        unlocker.unlock(bob);

        // unlocker should have up to date info
        assertEq(unlocker.lockedBalances(bob), 0, "locked balance incorrect");
        assertEq(keccak256(unlocker.lockDatas(bob)), keccak256(bytes("")), "lock data incorrect");
    }

    function test_referrerIsImmutable() external {
        address referrer0 = address(0);
        address referrer1 = address(1);
        address referrer2 = address(2);

        // mint tokens to `bob` with referrer 1
        token.mint(bob, 1 ether, referrer1);

        // referrer should be 1
        assertEq(token.referrerOf(bob), referrer1, "referrer incorrect");

        // score of referrer 1 should be 1 ether
        assertEq(token.scoreOf(referrer1), 1 ether, "referrer1 score incorrect");

        // mint tokens to `bob` with referrer 2
        token.mint(bob, 1 ether, referrer2);

        // referrer should still be 1
        assertEq(token.referrerOf(bob), referrer1, "referrer incorrect");

        // score of referrer 1 should be 2 ether
        assertEq(token.scoreOf(referrer1), 2 ether, "referrer1 score incorrect");

        // score of referrer 2 should be 0
        assertEq(token.scoreOf(referrer2), 0, "referrer2 score incorrect");

        // mint tokens to `bob` with referrer 0
        token.mint(bob, 1 ether, referrer0);

        // referrer should still be 1
        assertEq(token.referrerOf(bob), referrer1, "referrer incorrect");

        // score of referrer 1 should be 3 ether
        assertEq(token.scoreOf(referrer1), 3 ether, "referrer1 score incorrect");

        // score of referrer 0 should be 0
        assertEq(token.scoreOf(referrer0), 0, "referrer0 score incorrect");

        // mint tokens to `bob` with referrer 1
        token.mint(bob, 1 ether, referrer1);

        // referrer should still be 1
        assertEq(token.referrerOf(bob), referrer1, "referrer incorrect");

        // score of referrer 1 should be 4 ether
        assertEq(token.scoreOf(referrer1), 4 ether, "referrer1 score incorrect");
    }
}
