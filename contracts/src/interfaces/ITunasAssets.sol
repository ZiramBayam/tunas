// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface IWETH is IERC20 {
    function deposit() external payable;
}

interface IWithdrawalQueue {
    struct Status {
        uint256 amountOfStETH;
        uint256 amountOfShares;
        address owner;
        uint256 timestamp;
        bool isFinalized;
        bool isClaimed;
    }
    function ownerOf(uint256) external view returns (address);
    function safeTransferFrom(address, address, uint256) external;
    function getWithdrawalStatus(uint256[] calldata) external view returns (Status[] memory);
    function claimWithdrawals(uint256[] calldata, uint256[] calldata) external;
    function requestWithdrawals(uint256[] calldata, address) external returns (uint256[] memory);
    function approve(address, uint256) external;
    function getLastFinalizedRequestId() external view returns (uint256);
    function getLastCheckpointIndex() external view returns (uint256);
    function findCheckpointHints(uint256[] calldata, uint256, uint256)
        external
        view
        returns (uint256[] memory);
}
