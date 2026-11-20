// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {TunasReceipt, TunasReceiptCore} from "./TunasReceipt.sol";
import {IWETH, IWithdrawalQueue} from "./interfaces/ITunasAssets.sol";

interface ITunasFactory {
    function create(uint256 requestId) external returns (TunasReceiptCore);
    function created(address receipt) external view returns (bool);
    function weth() external view returns (IWETH);
}

contract TunasFactory is ITunasFactory {
    IWithdrawalQueue public immutable queue;
    IWETH public immutable override weth;
    address public immutable implementation;
    mapping(address => bool) public override created;

    event ReceiptCreated(uint256 indexed requestId, address indexed receipt, address indexed creator);

    constructor(IWithdrawalQueue withdrawalQueue, IWETH wrappedEther) {
        queue = withdrawalQueue;
        weth = wrappedEther;
        implementation = address(new TunasReceipt());
    }

    function create(uint256 requestId) external returns (TunasReceiptCore receipt) {
        // ERC-1167 creation code and fixed-target runtime.
        bytes memory creation = abi.encodePacked(
            hex"3d602d80600a3d3981f3",
            hex"363d3d373d3d3d363d73",
            bytes20(implementation),
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        address clone;
        assembly ("memory-safe") {
            clone := create(0, add(creation, 0x20), mload(creation))
        }
        require(clone != address(0) && clone.code.length == 45, "clone deployment failed");
        TunasReceipt(payable(clone)).initialize(queue, weth, requestId);
        created[clone] = true;
        emit ReceiptCreated(requestId, clone, msg.sender);
        receipt = TunasReceiptCore(payable(clone));
    }
}
