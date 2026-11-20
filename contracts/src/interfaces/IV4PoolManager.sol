// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct ModifyLiquidityParams {
    int24 tickLower;
    int24 tickUpper;
    int256 liquidityDelta;
    bytes32 salt;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IV4PoolManager {
    function initialize(PoolKey calldata key, uint160 sqrtPriceX96) external returns (int24);
    function unlock(bytes calldata data) external returns (bytes memory);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
    function mint(address to, uint256 id, uint256 amount) external;
    function burn(address from, uint256 id, uint256 amount) external;
    function balanceOf(address owner, uint256 id) external view returns (uint256);
    function take(address currency, address to, uint256 amount) external;
}
