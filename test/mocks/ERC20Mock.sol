// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {ERC20} from "../../src/base/ERC20.sol";

contract ERC20Mock is ERC20 {
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function burn(uint256 amount) public {
        _burn(msg.sender, amount);
    }

    function name() public pure override returns (string memory) {
        return "MockERC20";
    }

    function symbol() public pure override returns (string memory) {
        return "MOCK-ERC20";
    }
}
