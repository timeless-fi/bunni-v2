// SPDX-License-Identifier: AGPL-3.0

pragma solidity >=0.6.0;
pragma abicoder v2;

interface ILiquidityDensityFunction {
    function query(int24 roundedTick, int24 twapTick, int24 tickSpacing, bool useTwap, bytes32 ldfParams)
        external
        view
        returns (uint256 liquidityDensityX96, uint256 cumulativeAmount0DensityX96, uint256 cumulativeAmount1DensityX96);

    function liquidityDensityX96(int24 roundedTick, int24 twapTick, int24 tickSpacing, bool useTwap, bytes32 ldfParams)
        external
        view
        returns (uint256);

    function isValidParams(int24 tickSpacing, uint24 twapSecondsAgo, bytes32 ldfParamss) external view returns (bool);
}
