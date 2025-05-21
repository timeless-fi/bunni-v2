// SPDX-License-Identifier: MIT

pragma solidity ^0.8.15;

import {ERC20} from "solady/tokens/ERC20.sol";
import {ERC4626} from "solady/tokens/ERC4626.sol";

import {IERC20} from "../../src/interfaces/IERC20.sol";

contract ERC4626Mock is ERC4626 {
    address internal immutable _asset;

    constructor(IERC20 asset_) {
        _asset = address(asset_);
    }

    function asset() public view override returns (address) {
        return _asset;
    }

    function name() public pure override returns (string memory) {
        return "MockERC4626";
    }

    function symbol() public pure override returns (string memory) {
        return "MOCK-ERC4626";
    }
}

contract ERC4626FeeMock is ERC4626 {
    address internal immutable _asset;
    uint256 public fee;
    uint256 internal constant MAX_FEE = 10000;

    constructor(IERC20 asset_, uint256 _fee) {
        _asset = address(asset_);
        if (_fee > MAX_FEE) revert();
        fee = _fee;
    }

    function setFee(uint256 newFee) external {
        if (newFee > MAX_FEE) revert();
        fee = newFee;
    }

    function deposit(uint256 assets, address to) public override returns (uint256 shares) {
        return super.deposit(assets - assets * fee / MAX_FEE, to);
    }

    function asset() public view override returns (address) {
        return _asset;
    }

    function name() public pure override returns (string memory) {
        return "MockERC4626";
    }

    function symbol() public pure override returns (string memory) {
        return "MOCK-ERC4626";
    }
}
