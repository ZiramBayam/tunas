// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Vm} from "./helpers/ForkInterfaces.sol";
import {FullFactory} from "./helpers/FullFactory.sol";
import {IWithdrawalQueue, IWETH} from "../src/interfaces/ITunasAssets.sol";
import {ITunasFactory, TunasFactory} from "../src/TunasFactory.sol";
import {TunasReceipt, TunasReceiptCore} from "../src/TunasReceipt.sol";
import {TunasLocalTest, ModelQueue, ModelWETH} from "./TunasLocal.t.sol";
import {TunasForkTest} from "./TunasFork.t.sol";
import {TunasHaircutForkTest} from "./TunasHaircutFork.t.sol";

contract TunasCloneLocalTest is TunasLocalTest {
    TunasFactory private cloneFactory;

    function _newReceipt(uint256 id) internal override returns (TunasReceiptCore) {
        if (address(cloneFactory) == address(0)) cloneFactory = new TunasFactory(q, IWETH(address(w)));
        return cloneFactory.create(id);
    }
}

contract TunasCloneForkTest is TunasForkTest {
    function _newFactory(IWithdrawalQueue q, IWETH w) internal override returns (ITunasFactory) {
        return new TunasFactory(q, w);
    }
}

contract TunasCloneHaircutForkTest is TunasHaircutForkTest {
    function _newFactory(IWithdrawalQueue q, IWETH w) internal override returns (ITunasFactory) {
        return new TunasFactory(q, w);
    }
}

contract TunasCloneSecurityTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    ModelQueue private queue;
    ModelWETH private weth;
    TunasFactory private factory;
    event log_named_uint(string key, uint256 value);

    function setUp() public {
        queue = new ModelQueue();
        weth = new ModelWETH();
        factory = new TunasFactory(queue, IWETH(address(weth)));
    }

    function _init(address target, uint256 id) private returns (bool ok) {
        (ok,) = target.call(abi.encodeCall(TunasReceipt.initialize, (queue, IWETH(address(weth)), id)));
    }

    function test_should_reject_initialization_of_shared_implementation() public {
        require(!_init(factory.implementation(), 1), "implementation initialized by caller");
    }

    function test_should_create_exact_fixed_target_runtime_and_initialize_bindings_atomically() public {
        TunasReceiptCore receipt = factory.create(17);
        bytes memory expected = abi.encodePacked(
            hex"363d3d373d3d3d363d73", bytes20(factory.implementation()), hex"5af43d82803e903d91602b57fd5bf3"
        );
        require(keccak256(address(receipt).code) == keccak256(expected), "wrong implementation/runtime");
        require(
            address(receipt.queue()) == address(queue) && address(receipt.weth()) == address(weth)
                && receipt.requestId() == 17,
            "wrong binding"
        );
        require(factory.created(address(receipt)) && receipt.totalSupply() == 0, "premature supply");
    }

    function test_should_reject_reinitialization_and_preserve_request_binding() public {
        TunasReceiptCore receipt = factory.create(1);
        require(!_init(address(receipt), 2), "reinitialized");
        require(receipt.requestId() == 1 && address(receipt.queue()) == address(queue), "binding changed");
    }

    function test_should_isolate_storage_between_clones_and_implementation() public {
        TunasReceiptCore first = factory.create(1);
        TunasReceiptCore second = factory.create(2);
        queue.create(1, address(this), 100 ether);
        queue.approve(address(first), 1);
        first.wrap();
        require(
            first.totalSupply() == 100 ether && first.balanceOf(address(this)) == 100 ether,
            "first clone missing shares"
        );
        require(
            second.totalSupply() == 0 && second.balanceOf(address(this)) == 0 && second.requestId() == 2,
            "second clone contaminated"
        );
        require(
            TunasReceipt(payable(factory.implementation())).totalSupply() == 0,
            "implementation storage contaminated"
        );
        vm.prank(address(0xBAD));
        require(!_init(address(first), 3), "attacker reset clone");
        require(first.requestId() == 1 && queue.ownerOf(1) == address(first), "attacker changed custody");
    }

    function test_measure_system_factory_deployment_and_matched_receipt_creation() public {
        uint256 g = gasleft();
        ITunasFactory full = new FullFactory(queue, IWETH(address(weth)));
        emit log_named_uint("full_factory_deployment_internal_gas", g - gasleft());
        g = gasleft();
        TunasFactory clones = new TunasFactory(queue, IWETH(address(weth)));
        emit log_named_uint("clone_factory_plus_implementation_deployment_internal_gas", g - gasleft());
        g = gasleft();
        full.create(1);
        emit log_named_uint("full_receipt_create_internal_gas", g - gasleft());
        g = gasleft();
        clones.create(1);
        emit log_named_uint("clone_receipt_create_internal_gas", g - gasleft());
    }
}
