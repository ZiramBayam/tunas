// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Vm, IUniversalRouter, IPermit2, forkEthereum} from "./helpers/ForkInterfaces.sol";
import {FullFactory} from "./helpers/FullFactory.sol";
import {PoolKey, IV4PoolManager} from "../src/interfaces/IV4PoolManager.sol";
import {IWithdrawalQueue, IWETH} from "../src/interfaces/ITunasAssets.sol";
import {ITunasFactory} from "../src/TunasFactory.sol";
import {TunasReceiptCore} from "../src/TunasReceipt.sol";
import {TunasHook} from "../src/TunasHook.sol";
import {ModelQueue} from "./TunasLocal.t.sol";

// Model haircut with forked WETH and v4.
contract TunasHaircutForkTest {
    struct ExactInput {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    IV4PoolManager private constant pm = IV4PoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address private constant ROUTER = address(bytes20(hex"66a9893cc07d91d95644aedd05d03f95e1dba8af"));
    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    IWETH private constant weth = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    ModelQueue private queue;
    ITunasFactory private factory;
    TunasHook private market;
    TunasReceiptCore private receipt;
    PoolKey private key;
    uint256 private sellerCashBefore;
    event log_named_uint(string key, uint256 value);
    receive() external payable {}

    function _newFactory(IWithdrawalQueue q, IWETH w) internal virtual returns (ITunasFactory) {
        return new FullFactory(q, w);
    }

    function setUp() public virtual {
        forkEthereum(vm);
        vm.deal(address(this), 1000 ether);
        sellerCashBefore = weth.balanceOf(address(this));
        queue = new ModelQueue();
        factory = _newFactory(IWithdrawalQueue(address(queue)), weth);
        TunasHook implementation = new TunasHook(pm, factory, address(this), address(this));
        vm.etch(address(0x12A88), address(implementation).code);
        market = TunasHook(address(0x12A88));
        weth.deposit{value: 100 ether}();
        weth.approve(address(market), type(uint256).max);
        market.fund(100 ether);
        queue.create(1, address(this), 100 ether);
        receipt = factory.create(1);
        queue.approve(address(receipt), 1);
        receipt.wrap();
        key = market.bid(address(receipt), 20 ether, 0.995 ether, uint64(block.timestamp + 1 days));
        receipt.approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(address(receipt), ROUTER, type(uint160).max, type(uint48).max);
        bytes[] memory p = new bytes[](3);
        p[0] = abi.encode(
            ExactInput(key, key.currency0 == address(receipt), uint128(10 ether), uint128(9.95 ether), "")
        );
        p[1] = abi.encode(address(receipt), 10 ether);
        p[2] = abi.encode(address(weth), 9.95 ether);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(hex"060c0f", p);
        IUniversalRouter(ROUTER).execute(hex"10", inputs, block.timestamp + 1);
    }

    function _settleModel(uint256 payout) private {
        queue.finalizeModel(1, payout);
        vm.deal(address(queue), payout);
        receipt.claim(1);
    }

    function test_should_recycle_only_reserve_fraction_after_local_haircut_and_preserve_retained_payout()
        public
    {
        _settleModel(98 ether);
        market.release(address(receipt));
        uint256 capitalCash = market.cash();
        uint256 recycled = market.recycle(address(receipt), 10 ether);
        require(
            recycled == 9.8 ether && capitalCash == 90.05 ether && market.cash() == 99.85 ether, "loss hidden"
        );
        require(
            receipt.balanceOf(address(this)) == 90 ether && weth.balanceOf(address(receipt)) == 88.2 ether,
            "retained payout taken"
        );
        uint256 retainedPayout = receipt.redeem(90 ether, address(this));
        emit log_named_uint("seller_weth_baseline_from_fork", sellerCashBefore);
        emit log_named_uint("seller_weth_final_actual", weth.balanceOf(address(this)));
        emit log_named_uint("seller_retained_payout_actual", retainedPayout);
        require(
            retainedPayout == 88.2 ether && weth.balanceOf(address(this)) - sellerCashBefore == 98.15 ether,
            "seller accounting"
        );
        require(
            receipt.totalSupply() == 0
                && pm.balanceOf(address(market), uint256(uint160(address(receipt)))) == 0,
            "unburned receipts"
        );
        emit log_named_uint("model_haircut_actual_payout", 98 ether);
        emit log_named_uint("model_reserve_final_weth", market.cash());
        emit log_named_uint(
            "model_seller_cash_plus_retained_payout", weth.balanceOf(address(this)) - sellerCashBefore
        );
    }

    function test_should_recycle_full_actual_payout_and_allow_capital_owner_to_withdraw_cash() public {
        _settleModel(100 ether);
        market.release(address(receipt));
        require(
            market.recycle(address(receipt), 10 ether) == 10 ether && market.cash() == 100.05 ether,
            "spread missing"
        );
        require(receipt.redeem(90 ether, address(this)) == 90 ether, "seller payout");
        market.withdrawCash(100.05 ether, address(0xC0FFEE));
        require(weth.balanceOf(address(0xC0FFEE)) == 100.05 ether && market.cash() == 0, "capital exit");
    }

    function test_should_not_recycle_pending_inventory_as_cash() public {
        (bool ok,) = address(market).call(abi.encodeCall(market.recycle, (address(receipt), 10 ether)));
        require(!ok && market.cash() == 90.05 ether && receipt.pending(), "invented pending cash");
    }
}
