// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {ERC20Lockable} from "../../src/base/ERC20Lockable.sol";

contract ERC20LockableMock is ERC20Lockable {
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function burn(uint256 amount) public {
        _burn(msg.sender, amount);
    }

    function name() public pure override returns (string memory) {
        return "MockERC20Lockable";
    }

    function symbol() public pure override returns (string memory) {
        return "MOCK-ERC20Lockable";
    }
}
