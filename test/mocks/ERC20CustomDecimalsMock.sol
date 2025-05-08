// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {ERC20} from "../../src/base/ERC20.sol";

contract ERC20CustomDecimalsMock is ERC20 {
    uint8 internal immutable _decimals;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

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
