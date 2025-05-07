// SPDX-License-Identifier: MIT

pragma solidity ^0.8.15;

import {ERC20} from "solady/tokens/ERC20.sol";
import {ERC4626} from "solady/tokens/ERC4626.sol";

import {IERC20} from "../../src/interfaces/IERC20.sol";

contract ERC4626Mock is ERC4626 {
    address internal immutable _asset;
    mapping(address to => bool maxDepostitCapped) internal maxDepositsCapped;

    error ZeroAssetsDeposit();

    constructor(IERC20 asset_) {
        _asset = address(asset_);
    }

    function deposit(uint256 assets, address to) public override returns (uint256 shares) {
        if (assets == 0) revert ZeroAssetsDeposit();
        return super.deposit(assets, to);
    }

    function setMaxDepositFor(address to) external {
        maxDepositsCapped[to] = true;
    }

    function maxDeposit(address to) public view override returns (uint256 maxAssets) {
        if (maxDepositsCapped[to]) {
            return 0;
        } else {
            return super.maxDeposit(to);
        }
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
