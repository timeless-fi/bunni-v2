// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import "forge-std/Test.sol";

import "../src/base/Constants.sol";
import "./mocks/ERC20LockableMock.sol";
import "./mocks/ERC20UnlockerMock.sol";
import {IERC20Lockable} from "../src/interfaces/IERC20Lockable.sol";

contract ERC20LockableTest is Test {
    ERC20LockableMock token;
    ERC20UnlockerMock unlocker;
    address bob = makeAddr("bob");
    address eve = makeAddr("eve");

    function setUp() public {
        token = new ERC20LockableMock();
        unlocker = new ERC20UnlockerMock(token);
    }

    function test_lockable_lock(uint256 amount, bytes calldata data) external {
        amount = bound(amount, 0, type(uint232).max);

        // mint `amount` tokens to `bob`
        token.mint(bob, amount);

        // lock account as `bob`
        vm.prank(bob);
        token.lock(unlocker, data);

        // check isLocked
        assertTrue(token.isLocked(bob), "isLocked returned false");

        // check unlocker
        assertEq(address(token.unlockerOf(bob)), address(unlocker), "unlocker incorrect");

        // check balance
        assertEq(token.balanceOf(bob), amount, "balance incorrect");

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

    function test_lockable_transferToLockedAccount(uint256 amount, bytes calldata data) external {
        amount = bound(amount, 0, type(uint232).max / 2);

        // mint `amount` tokens to `bob`
        token.mint(bob, amount);

        // lock account as `eve`
        vm.prank(eve);
        token.lock(unlocker, data);

        // transfer to locked account should succeed
        vm.prank(bob);
        token.transfer(eve, amount);

        // minting to locked account should succeed
        token.mint(eve, amount);

        // unlocker should have up to date info
        assertEq(unlocker.lockedBalances(eve), amount * 2, "locked balance incorrect");
        assertEq(keccak256(unlocker.lockDatas(eve)), keccak256(data), "lock data incorrect");

        // check balance
        assertEq(token.balanceOf(eve), amount * 2, "balance incorrect");

        // check isLocked
        assertTrue(token.isLocked(eve), "isLocked returned false");
    }

    function test_lockable_unlock(uint256 amount, bytes calldata data) external {
        amount = bound(amount, 0, type(uint232).max);

        // mint `amount` tokens to `bob`
        token.mint(bob, amount);

        // lock account as `bob`
        vm.prank(bob);
        token.lock(unlocker, data);

        // unlock `bob`
        unlocker.unlock(bob);

        // check isLocked
        assertFalse(token.isLocked(bob), "isLocked returned true after unlocking");

        // check balance
        assertEq(token.balanceOf(bob), amount, "balance incorrect");

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
}
