// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ITunasFactory} from "../../src/TunasFactory.sol";
import {TunasReceiptCore} from "../../src/TunasReceipt.sol";
import {IWETH, IWithdrawalQueue} from "../../src/interfaces/ITunasAssets.sol";

contract FullReceipt is TunasReceiptCore {
    IWithdrawalQueue private immutable boundQueue;
    IWETH private immutable boundWeth;
    uint256 private immutable boundRequestId;

    constructor(IWithdrawalQueue q, IWETH w, uint256 id) {
        boundQueue = q;
        boundWeth = w;
        boundRequestId = id;
    }

    function _queue() internal view override returns (IWithdrawalQueue) {
        return boundQueue;
    }

    function _weth() internal view override returns (IWETH) {
        return boundWeth;
    }

    function _requestId() internal view override returns (uint256) {
        return boundRequestId;
    }
}

contract FullFactory is ITunasFactory {
    IWithdrawalQueue public immutable queue;
    IWETH public immutable weth;
    mapping(address => bool) public created;

    constructor(IWithdrawalQueue q, IWETH w) {
        queue = q;
        weth = w;
    }

    function create(uint256 id) external virtual returns (TunasReceiptCore r) {
        r = new FullReceipt(queue, weth, id);
        created[address(r)] = true;
    }
}
