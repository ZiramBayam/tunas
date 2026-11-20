// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Vm} from "./helpers/ForkInterfaces.sol";
import {ModelQueue, ModelWETH} from "./TunasLocal.t.sol";
import {TunasFactory} from "../src/TunasFactory.sol";
import {TunasReceiptCore} from "../src/TunasReceipt.sol";

contract ReceiptCreatedTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes32 private constant RECEIPT_CREATED = keccak256("ReceiptCreated(uint256,address,address)");

    function test_create_emits_registered_receipt_and_creator() public {
        ModelQueue queue = new ModelQueue();
        ModelWETH weth = new ModelWETH();
        TunasFactory factory = new TunasFactory(queue, weth);

        vm.recordLogs();
        TunasReceiptCore receipt = factory.create(17);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        require(factory.created(address(receipt)) && receipt.requestId() == 17, "wrong binding");
        require(logs.length == 1 && logs[0].emitter == address(factory), "missing factory event");
        bytes32[] memory topics = logs[0].topics;
        require(topics.length == 4 && topics[0] == RECEIPT_CREATED, "wrong event");
        require(uint256(topics[1]) == 17, "wrong request ID");
        require(address(uint160(uint256(topics[2]))) == address(receipt), "wrong receipt");
        require(address(uint160(uint256(topics[3]))) == address(this), "wrong creator");
    }
}
