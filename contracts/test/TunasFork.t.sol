// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {
    Vm,
    IStateView,
    IQuoter,
    IUniversalRouter,
    IPermit2,
    IStETH,
    forkEthereum
} from "./helpers/ForkInterfaces.sol";
import {FullFactory} from "./helpers/FullFactory.sol";
import {PoolKey, IV4PoolManager} from "../src/interfaces/IV4PoolManager.sol";
import {IERC20, IWithdrawalQueue, IWETH} from "../src/interfaces/ITunasAssets.sol";
import {ITunasFactory} from "../src/TunasFactory.sol";
import {TunasReceiptCore} from "../src/TunasReceipt.sol";
import {TunasHook} from "../src/TunasHook.sol";

contract TunasForkTest {
    struct ExactInput {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    struct EndState {
        uint256 sellerCash;
        uint256 sellerReceipts;
        uint256 reserveCash;
        uint256 reserveReceipts;
        uint256 reserved;
        uint256 capacity;
        uint256 quoteCash;
        address nftOwner;
        uint256 supply;
    }
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    IV4PoolManager private constant pm = IV4PoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IStateView private constant sv = IStateView(0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227);
    address private constant ROUTER = address(bytes20(hex"66a9893cc07d91d95644aedd05d03f95e1dba8af"));
    address private constant QUOTER = address(bytes20(hex"99bd42b2b22e531f283b7f8a86dff631eb16a9d1"));
    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address private constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    IWETH private constant weth = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IWithdrawalQueue private constant queue = IWithdrawalQueue(0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1);
    address private constant RECIPIENT = address(0xB0B);
    uint256 private constant PRICE = 0.995 ether;
    ITunasFactory private factory;
    TunasHook private market;
    TunasReceiptCore private receipt;
    PoolKey private key;
    uint256 private requestId;
    event log_named_uint(string key, uint256 value);
    receive() external payable {}

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02;
    }

    function _newFactory(IWithdrawalQueue q, IWETH w) internal virtual returns (ITunasFactory) {
        return new FullFactory(q, w);
    }

    function setUp() public virtual {
        forkEthereum(vm);
        require(IQuoter(QUOTER).poolManager() == address(pm), "wrong deployed quoter");
        vm.deal(address(this), 1000 ether);
        factory = _newFactory(queue, weth);
        TunasHook implementation = new TunasHook(pm, factory, address(this), address(this));
        vm.etch(address(0x2A88), address(implementation).code);
        market = TunasHook(address(0x2A88));
        weth.deposit{value: 100 ether}();
        weth.approve(address(market), type(uint256).max);
        market.fund(100 ether);
        IStETH(STETH).submit{value: 101 ether}(address(0));
        IERC20(STETH).approve(address(queue), type(uint256).max);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100 ether;
        requestId = queue.requestWithdrawals(amounts, address(this))[0];
        receipt = factory.create(requestId);
        queue.approve(address(receipt), requestId);
        receipt.wrap();
        key = market.bid(address(receipt), 20 ether, PRICE, uint64(block.timestamp + 1 days));
        receipt.approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(address(receipt), ROUTER, type(uint160).max, type(uint48).max);
        receipt.approve(address(market), type(uint256).max);
    }

    function _router(uint256 amount, uint256 minimum) private returns (uint256 output) {
        bytes[] memory p = new bytes[](3);
        p[0] = abi.encode(
            ExactInput(key, key.currency0 == address(receipt), uint128(amount), uint128(minimum), "")
        );
        p[1] = abi.encode(address(receipt), amount);
        p[2] = abi.encode(address(weth), minimum);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(hex"060c0f", p);
        uint256 beforeCash = weth.balanceOf(address(this));
        IUniversalRouter(ROUTER).execute(hex"10", inputs, block.timestamp + 1);
        return weth.balanceOf(address(this)) - beforeCash;
    }

    function routerSale(uint256 amount, uint256 minimum) external returns (uint256) {
        return _router(amount, minimum);
    }

    function _capture() private view returns (EndState memory e) {
        (, uint256 remaining, uint256 cash,) = market.bids(address(receipt));
        return EndState(
            weth.balanceOf(address(this)),
            receipt.balanceOf(address(this)),
            market.cash(),
            pm.balanceOf(address(market), uint256(uint160(address(receipt)))),
            market.totalReserved(),
            remaining,
            cash,
            queue.ownerOf(requestId),
            receipt.totalSupply()
        );
    }

    function test_should_sell_ten_percent_through_deployed_router_and_retain_ninety_percent_of_pending_claim()
        public
    {
        uint256 cashBefore = weth.balanceOf(address(this));
        uint256 out = _router(10 ether, 9.95 ether);
        require(out == 9.95 ether && weth.balanceOf(address(this)) == cashBefore + out, "cash paid");
        require(
            receipt.balanceOf(address(this)) == 90 ether && receipt.totalSupply() == 100 ether,
            "retained rights"
        );
        require(queue.ownerOf(requestId) == address(receipt) && receipt.pending(), "NFT custody/state");
        require(
            market.cash() == 90.05 ether
                && pm.balanceOf(address(market), uint256(uint160(address(receipt)))) == 10 ether,
            "backed fill"
        );
        require(sv.getLiquidity(keccak256(abi.encode(key))) == 0, "unexpected native liquidity");
        require(weth.balanceOf(ROUTER) == 0 && receipt.balanceOf(ROUTER) == 0, "router dust");
        emit log_named_uint("sold_receipts", 10 ether);
        emit log_named_uint("seller_weth_received", out);
        emit log_named_uint("seller_retained_receipts", receipt.balanceOf(address(this)));
        emit log_named_uint("real_pending_request_id", requestId);
    }

    function test_should_quote_without_spending_reserve_or_receipts_then_match_router_output() public {
        EndState memory beforeState = _capture();
        (uint256 quoted,) = IQuoter(QUOTER)
            .quoteExactInputSingle(
                IQuoter.QuoteParams(key, key.currency0 == address(receipt), uint128(10 ether), "")
            );
        require(
            keccak256(abi.encode(beforeState)) == keccak256(abi.encode(_capture())), "quote persisted state"
        );
        require(quoted == 9.95 ether && _router(10 ether, quoted) == quoted, "quote/execute");
    }

    function test_should_match_direct_otc_fill_with_same_receipt_quote_and_funded_reserve() public {
        uint256 snap = vm.snapshotState();
        uint256 outDirect = market.sellDirect(address(receipt), 10 ether, 9.95 ether, address(this));
        EndState memory d = _capture();
        require(vm.revertToState(snap), "snapshot");
        uint256 outHook = _router(10 ether, 9.95 ether);
        require(
            outDirect == outHook && keccak256(abi.encode(d)) == keccak256(abi.encode(_capture())),
            "economic outcomes differ"
        );
    }

    function test_should_rollback_sale_and_bid_accounting_when_user_minimum_fails() public {
        EndState memory beforeState = _capture();
        (bool ok,) = address(this).call(abi.encodeCall(this.routerSale, (10 ether, 10 ether)));
        require(
            !ok && keccak256(abi.encode(beforeState)) == keccak256(abi.encode(_capture())), "minimum rollback"
        );
    }

    function test_should_reject_sale_above_committed_capacity_and_keep_state() public {
        EndState memory beforeState = _capture();
        (bool ok,) = address(this).call(abi.encodeCall(this.routerSale, (21 ether, 0)));
        require(
            !ok && keccak256(abi.encode(beforeState)) == keccak256(abi.encode(_capture())),
            "capacity rollback"
        );
    }

    function test_should_prevent_capital_owner_withdrawing_live_bid_commitment() public {
        (bool ok,) = address(market).call(abi.encodeCall(market.withdrawCash, (81 ether, address(this))));
        require(!ok, "reserved cash withdrawn");
        market.withdrawCash(80.1 ether, address(this));
        require(market.cash() == 19.9 ether && market.freeCash() == 0, "reserve accounting");
        require(_router(20 ether, 19.9 ether) == 19.9 ether && market.cash() == 0, "funded bid failed");
    }

    function test_should_expire_bid_and_release_only_its_cash_commitment() public {
        vm.warp(block.timestamp + 1 days);
        (bool ok,) = address(this).call(abi.encodeCall(this.routerSale, (10 ether, 0)));
        require(!ok, "expired fill");
        market.release(address(receipt));
        require(market.totalReserved() == 0 && market.cash() == 100 ether, "release cash");
        require(
            receipt.balanceOf(address(this)) == 100 ether && queue.ownerOf(requestId) == address(receipt),
            "expiry stole claim"
        );
    }

    function test_should_keep_real_pending_request_unclaimable_after_time_passes() public {
        _router(10 ether, 0);
        vm.warp(block.timestamp + 30 days);
        require(receipt.pending(), "warp finalized request");
        (bool ok,) = address(receipt).call(abi.encodeCall(receipt.claim, (0)));
        require(!ok && !receipt.settled() && weth.balanceOf(address(receipt)) == 0, "pending became cash");
    }

    function test_should_deny_whole_nft_exit_to_ninety_percent_seller_and_curator() public {
        _router(10 ether, 0);
        (bool ok,) = address(receipt).call(abi.encodeCall(receipt.unwrap, (address(this))));
        require(!ok, "partial seized NFT");
        vm.prank(address(market));
        (ok,) = address(receipt).call(abi.encodeCall(receipt.unwrap, (RECIPIENT)));
        require(!ok, "reserve seized NFT");
        require(queue.ownerOf(requestId) == address(receipt), "NFT moved");
    }

    function test_should_reject_unfunded_additional_bid_and_reject_unapproved_curator() public {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        uint256 id = queue.requestWithdrawals(amounts, address(this))[0];
        TunasReceiptCore other = factory.create(id);
        queue.approve(address(other), id);
        other.wrap();
        vm.prank(RECIPIENT);
        (bool ok,) = address(market)
            .call(
                abi.encodeCall(market.bid, (address(other), 1 ether, PRICE, uint64(block.timestamp + 1 days)))
            );
        require(!ok, "outsider changed quote");
        market.withdrawCash(market.freeCash(), address(this));
        (ok,) = address(market)
            .call(
                abi.encodeCall(market.bid, (address(other), 1 ether, PRICE, uint64(block.timestamp + 1 days)))
            );
        require(!ok && market.totalReserved() == 19.9 ether, "unfunded commitment");
    }

    function test_should_redeem_real_finalized_lido_payout_proportionally_and_burn_receipts() public {
        uint256 last = queue.getLastFinalizedRequestId();
        uint256[] memory ids = new uint256[](16);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = last - i;
        }
        IWithdrawalQueue.Status[] memory states = queue.getWithdrawalStatus(ids);
        uint256 chosen;
        address originalOwner;
        for (uint256 i; i < ids.length; ++i) {
            if (states[i].isFinalized && !states[i].isClaimed && states[i].amountOfStETH >= 10) {
                chosen = ids[i];
                originalOwner = states[i].owner;
                break;
            }
        }
        require(chosen != 0, "no unclaimed finalized request in bounded sample");
        TunasReceiptCore finalReceipt = factory.create(chosen);
        // Fork fixture for holder consent.
        vm.prank(originalOwner);
        queue.approve(address(finalReceipt), chosen);
        vm.prank(originalOwner);
        finalReceipt.wrap();
        uint256 supply = finalReceipt.totalSupply();
        uint256 portion = supply / 10;
        vm.prank(originalOwner);
        finalReceipt.transfer(RECIPIENT, portion);
        uint256[] memory selected = new uint256[](1);
        selected[0] = chosen;
        uint256 hint = queue.findCheckpointHints(selected, 1, queue.getLastCheckpointIndex())[0];
        uint256 received = finalReceipt.claim(hint);
        require(received > 0 && finalReceipt.realized() == received, "no real payout");
        uint256 beforeA = weth.balanceOf(originalOwner);
        uint256 beforeB = weth.balanceOf(RECIPIENT);
        vm.prank(originalOwner);
        uint256 a = finalReceipt.redeem(supply - portion, originalOwner);
        vm.prank(RECIPIENT);
        uint256 b = finalReceipt.redeem(portion, RECIPIENT);
        require(
            a + b == received && weth.balanceOf(originalOwner) == beforeA + a
                && weth.balanceOf(RECIPIENT) == beforeB + b,
            "actual payout split"
        );
        require(
            finalReceipt.totalSupply() == 0 && weth.balanceOf(address(finalReceipt)) == 0, "leftover payout"
        );
        require(queue.getWithdrawalStatus(selected)[0].isClaimed, "NFT not claimed");
        emit log_named_uint("already_finalized_lido_request_id", chosen);
        emit log_named_uint("actual_lido_eth_payout", received);
        emit log_named_uint("retained_holder_real_weth_payout", a);
        emit log_named_uint("fraction_holder_real_weth_payout", b);
    }

    function test_measure_direct_otc_same_reserve() public {
        uint256 gasBefore = gasleft();
        market.sellDirect(address(receipt), 10 ether, 0, address(this));
        emit log_named_uint("direct_otc_internal_gas", gasBefore - gasleft());
    }

    function test_measure_request_wrapper_onboarding_and_first_small_partial_sale() public {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0.5 ether;
        uint256 id = queue.requestWithdrawals(amounts, address(this))[0];
        uint256 totalStart = gasleft();
        uint256 stageStart = gasleft();
        TunasReceiptCore small = factory.create(id);
        emit log_named_uint("onboarding_receipt_deploy_internal_gas", stageStart - gasleft());
        stageStart = gasleft();
        queue.approve(address(small), id);
        small.wrap();
        emit log_named_uint("onboarding_nft_approve_wrap_internal_gas", stageStart - gasleft());
        stageStart = gasleft();
        PoolKey memory smallKey =
            market.bid(address(small), 0.1 ether, PRICE, uint64(block.timestamp + 1 days));
        emit log_named_uint("onboarding_curator_bid_and_pool_init_internal_gas", stageStart - gasleft());
        stageStart = gasleft();
        small.approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(address(small), ROUTER, type(uint160).max, type(uint48).max);
        emit log_named_uint("onboarding_receipt_permit2_approvals_internal_gas", stageStart - gasleft());
        bytes[] memory p = new bytes[](3);
        p[0] = abi.encode(
            ExactInput(
                smallKey,
                smallKey.currency0 == address(small),
                uint128(0.05 ether),
                uint128(0.04975 ether),
                ""
            )
        );
        p[1] = abi.encode(address(small), 0.05 ether);
        p[2] = abi.encode(address(weth), 0.04975 ether);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(hex"060c0f", p);
        uint256 beforeCash = weth.balanceOf(address(this));
        IUniversalRouter(ROUTER).execute(hex"10", inputs, block.timestamp + 1);
        require(
            weth.balanceOf(address(this)) - beforeCash == 0.04975 ether
                && small.balanceOf(address(this)) == 0.45 ether,
            "small partial sale"
        );
        emit log_named_uint(
            "onboarding_and_first_sale_internal_gas_including_log_cost", totalStart - gasleft()
        );
    }

    function test_measure_v4_router_partial_sale() public {
        uint256 gasBefore = gasleft();
        _router(10 ether, 0);
        emit log_named_uint("v4_router_internal_gas", gasBefore - gasleft());
    }
}
