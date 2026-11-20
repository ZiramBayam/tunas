// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {PoolKey} from "../../src/interfaces/IV4PoolManager.sol";

interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function createSelectFork(string calldata url, uint256 blockNumber) external returns (uint256);
    function envOr(string calldata name, string calldata defaultValue) external view returns (string memory);
    function etch(address target, bytes calldata code) external;
    function prank(address sender) external;
    function deal(address who, uint256 amount) external;
    function warp(uint256 timestamp) external;
    function snapshotState() external returns (uint256);
    function revertToState(uint256 snapshotId) external returns (bool);
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
    function expectEmit(bool topic1, bool topic2, bool topic3, bool data, address emitter) external;
    function expectCall(address callee, bytes calldata data) external;
    function expectRevert() external;
    function expectRevert(bytes4 selector) external;
}

interface IQuoter {
    struct QuoteParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    function poolManager() external view returns (address);
    function quoteExactInputSingle(QuoteParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IStateView {
    function getLiquidity(bytes32 poolId) external view returns (uint128);
}

interface IStETH {
    function submit(address referral) external payable returns (uint256);
}

function forkEthereum(Vm vm) {
    vm.createSelectFork(vm.envOr("TUNAS_FORK_RPC_URL", string("http://127.0.0.1:18546")), 26_426_211);
}
