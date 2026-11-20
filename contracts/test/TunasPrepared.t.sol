// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Vm, IQuoter, IUniversalRouter, IPermit2, IStETH, forkEthereum} from "./helpers/ForkInterfaces.sol";
import {PoolKey, IV4PoolManager} from "../src/interfaces/IV4PoolManager.sol";
import {IERC20, IWithdrawalQueue, IWETH} from "../src/interfaces/ITunasAssets.sol";
import {TunasFactory} from "../src/TunasFactory.sol";
import {TunasReceiptCore} from "../src/TunasReceipt.sol";
import {TunasHook} from "../src/TunasHook.sol";
import {ModelQueue} from "./TunasLocal.t.sol";

abstract contract PreparedFixture {
    struct ExactInput {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    IV4PoolManager internal constant pm = IV4PoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address internal constant ROUTER = address(bytes20(hex"66a9893cc07d91d95644aedd05d03f95e1dba8af"));
    address internal constant QUOTER = address(bytes20(hex"99bd42b2b22e531f283b7f8a86dff631eb16a9d1"));
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    IWithdrawalQueue internal constant LIDO = IWithdrawalQueue(0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1);
    IWETH internal constant weth = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address internal constant SELLER = address(0x5100);
    address internal constant NEW_OWNER = address(0x5200);
    address internal constant CURATOR = address(0xC0A);
    address internal constant CAPITAL = address(0xCA901);
    uint256 internal constant PRICE = 0.995 ether;
    IWithdrawalQueue internal queue;
    TunasFactory internal factory;
    TunasHook internal market;
    TunasReceiptCore internal receipt;
    uint256 internal requestId;
    event log_named_uint(string key, uint256 value);
    receive() external payable {}

    function _source() internal virtual returns (IWithdrawalQueue, uint256) {
        ModelQueue model = new ModelQueue();
        model.create(1, SELLER, 100 ether);
        return (IWithdrawalQueue(address(model)), 1);
    }

    function _deployHook() internal virtual returns (TunasHook) {
        TunasHook implementation = new TunasHook(pm, factory, CURATOR, CAPITAL);
        vm.etch(address(0x32A88), address(implementation).code);
        return TunasHook(address(0x32A88));
    }

    function setUp() public {
        forkEthereum(vm);
        vm.deal(address(this), 1000 ether);
        vm.deal(SELLER, 10 ether);
        vm.deal(CURATOR, 10 ether);
        (queue, requestId) = _source();
        factory = new TunasFactory(queue, weth);
        market = _deployHook();
        weth.deposit{value: 100 ether}();
        weth.transfer(CAPITAL, 100 ether);
        vm.prank(CAPITAL);
        weth.approve(address(market), type(uint256).max);
        vm.prank(CAPITAL);
        market.fund(100 ether);
        vm.prank(CURATOR);
        receipt = factory.create(requestId);
    }

    function _commit(TunasReceiptCore r, uint256 units, uint64 until) internal returns (PoolKey memory k) {
        vm.prank(CURATOR);
        return market.bid(address(r), units, PRICE, until);
    }

    function _wrap(TunasReceiptCore r, address owner) internal {
        uint256 id = r.requestId();
        vm.prank(owner);
        queue.approve(address(r), id);
        vm.prank(owner);
        r.wrap();
    }

    function _approveRouter(TunasReceiptCore r, address owner) internal {
        vm.prank(owner);
        r.approve(PERMIT2, type(uint256).max);
        vm.prank(owner);
        IPermit2(PERMIT2).approve(address(r), ROUTER, type(uint160).max, type(uint48).max);
    }

    function _quote(TunasReceiptCore r, uint256 units) internal returns (uint256 out) {
        PoolKey memory k = market.keyFor(address(r));
        (out,) = IQuoter(QUOTER)
            .quoteExactInputSingle(IQuoter.QuoteParams(k, k.currency0 == address(r), uint128(units), ""));
    }

    function quote(TunasReceiptCore r, uint256 units) external returns (uint256) {
        return _quote(r, units);
    }

    function _sell(TunasReceiptCore r, address owner, uint256 units, uint256 minimum)
        internal
        returns (uint256)
    {
        return _sellWithDeadline(r, owner, units, minimum, block.timestamp + 1);
    }

    function _sellWithDeadline(
        TunasReceiptCore r,
        address owner,
        uint256 units,
        uint256 minimum,
        uint256 deadline
    ) internal returns (uint256) {
        PoolKey memory k = market.keyFor(address(r));
        bytes[] memory p = new bytes[](3);
        p[0] = abi.encode(ExactInput(k, k.currency0 == address(r), uint128(units), uint128(minimum), ""));
        p[1] = abi.encode(address(r), units);
        p[2] = abi.encode(address(weth), minimum);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(hex"060c0f", p);
        uint256 beforeCash = weth.balanceOf(owner);
        vm.prank(owner);
        IUniversalRouter(ROUTER).execute(hex"10", inputs, deadline);
        return weth.balanceOf(owner) - beforeCash;
    }

    function sale(TunasReceiptCore r, address owner, uint256 units, uint256 minimum)
        external
        returns (uint256)
    {
        return _sell(r, owner, units, minimum);
    }
}

// Model queue with forked WETH and v4.
contract TunasPreparedModelTest is PreparedFixture {
    function _model() private view returns (ModelQueue) {
        return ModelQueue(address(queue));
    }

    function test_should_fund_empty_clone_without_custody_or_supply_and_keep_cash_locked() public {
        _commit(receipt, 20 ether, uint64(block.timestamp + 1 days));
        require(
            receipt.totalSupply() == 0 && !receipt.wrapped() && queue.ownerOf(requestId) == SELLER,
            "premature custody/supply"
        );
        require(
            market.cash() == 100 ether && market.totalReserved() == 19.9 ether
                && market.freeCash() == 80.1 ether,
            "unbacked prepared quote"
        );
        (bool ok,) = address(market).call(abi.encodeCall(market.release, (address(receipt))));
        require(!ok, "empty clone released live cash");
        vm.prank(CAPITAL);
        (ok,) = address(market).call(abi.encodeCall(market.withdrawCash, (81 ether, CAPITAL)));
        require(!ok, "prepared commitment withdrawn");
    }

    function test_should_reject_both_direct_fill_and_quoter_until_actual_owner_wraps() public {
        _commit(receipt, 20 ether, uint64(block.timestamp + 1 days));
        (bool ok,) = address(this).call(abi.encodeCall(this.quote, (receipt, 10 ether)));
        require(!ok, "empty receipt quoted as tradable");
        vm.prank(SELLER);
        (ok,) =
            address(market).call(abi.encodeCall(market.sellDirect, (address(receipt), 10 ether, 0, SELLER)));
        require(!ok, "empty receipt sold");
        (ok,) = address(this).call(abi.encodeCall(this.sale, (receipt, SELLER, 10 ether, 0)));
        require(!ok, "router filled empty receipt");
        require(
            market.cash() == 100 ether && market.totalReserved() == 19.9 ether && receipt.totalSupply() == 0,
            "failed fill mutated backing"
        );
        _wrap(receipt, SELLER);
        _approveRouter(receipt, SELLER);
        require(
            _quote(receipt, 10 ether) == 9.95 ether
                && _sell(receipt, SELLER, 10 ether, 9.95 ether) == 9.95 ether,
            "wrapped fill mismatch"
        );
    }

    function test_should_keep_asset_bound_bid_when_nft_owner_changes_before_wrap() public {
        _commit(receipt, 20 ether, uint64(block.timestamp + 1 days));
        vm.prank(SELLER);
        queue.safeTransferFrom(SELLER, NEW_OWNER, requestId);
        vm.prank(SELLER);
        (bool ok,) = address(receipt).call(abi.encodeCall(receipt.wrap, ()));
        require(!ok, "former owner wrapped");
        _wrap(receipt, NEW_OWNER);
        _approveRouter(receipt, NEW_OWNER);
        require(
            _sell(receipt, NEW_OWNER, 10 ether, 9.95 ether) == 9.95 ether, "new owner cannot use asset bid"
        );
        require(
            receipt.balanceOf(SELLER) == 0 && receipt.balanceOf(NEW_OWNER) == 90 ether,
            "wrong seller entitlement"
        );
    }

    function test_should_close_unwrapped_receipt_permanently_release_bid_and_allow_new_wrapper() public {
        _commit(receipt, 20 ether, uint64(block.timestamp + 1 days));
        _wrap(receipt, SELLER);
        vm.prank(SELLER);
        receipt.unwrap(SELLER);
        require(
            receipt.closed() && receipt.totalSupply() == 0 && queue.ownerOf(requestId) == SELLER,
            "unwrap rights"
        );
        vm.prank(SELLER);
        (bool ok,) = address(receipt).call(abi.encodeCall(receipt.wrap, ()));
        require(!ok, "closed receipt reminted");
        market.release(address(receipt));
        require(market.totalReserved() == 0, "closed quote cash stuck");
        vm.prank(CURATOR);
        (ok,) = address(market)
            .call(
                abi.encodeCall(
                    market.bid, (address(receipt), 10 ether, PRICE, uint64(block.timestamp + 1 days))
                )
            );
        require(!ok, "closed wrapper got new bid");
        TunasReceiptCore fresh = factory.create(requestId);
        _commit(fresh, 10 ether, uint64(block.timestamp + 1 days));
        _wrap(fresh, SELLER);
        require(
            fresh.totalSupply() == 100 ether && receipt.totalSupply() == 0
                && queue.ownerOf(requestId) == address(fresh),
            "duplicate or lost rights"
        );
    }

    function test_should_expire_empty_bid_without_transferring_nft_or_minting_receipts() public {
        _commit(receipt, 20 ether, uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 1 days);
        market.release(address(receipt));
        require(market.cash() == 100 ether && market.freeCash() == 100 ether, "expiry did not release");
        require(queue.ownerOf(requestId) == SELLER && receipt.totalSupply() == 0, "expiry took custody");
    }

    function test_should_release_expired_cash_even_if_source_status_is_unavailable() public {
        _commit(receipt, 20 ether, uint64(block.timestamp + 1 days));
        vm.etch(address(queue), hex"");
        (bool ok,) = address(market).call(abi.encodeCall(market.release, (address(receipt))));
        require(!ok && market.totalReserved() == 19.9 ether, "unreadable source released live commitment");
        vm.warp(block.timestamp + 1 days);
        market.release(address(receipt));
        require(
            market.freeCash() == 100 ether && market.totalReserved() == 0,
            "expired cash depends on source availability"
        );
    }

    function test_should_release_empty_bid_when_source_finalizes_and_reject_new_pending_quote() public {
        _commit(receipt, 20 ether, uint64(block.timestamp + 1 days));
        _model().finalizeModel(requestId, 100 ether);
        market.release(address(receipt));
        require(market.freeCash() == 100 ether && receipt.totalSupply() == 0, "finalized source locked cash");
        vm.prank(CURATOR);
        (bool ok,) = address(market)
            .call(
                abi.encodeCall(
                    market.bid, (address(receipt), 10 ether, PRICE, uint64(block.timestamp + 1 days))
                )
            );
        require(!ok, "finalized source got pending bid");
    }

    function test_should_release_empty_bid_when_source_was_claimed_directly() public {
        _commit(receipt, 20 ether, uint64(block.timestamp + 1 days));
        _model().finalizeModel(requestId, 100 ether);
        vm.deal(address(queue), 100 ether);
        uint256[] memory ids = new uint256[](1);
        ids[0] = requestId;
        uint256[] memory hints = new uint256[](1);
        hints[0] = 1;
        vm.prank(SELLER);
        queue.claimWithdrawals(ids, hints);
        require(queue.getWithdrawalStatus(ids)[0].isClaimed, "source not claimed");
        market.release(address(receipt));
        require(market.freeCash() == 100 ether && receipt.totalSupply() == 0, "claimed source cash/rights");
    }

    function test_should_preserve_sold_rights_after_wrapped_source_finalizes_with_model_haircut() public {
        _commit(receipt, 20 ether, uint64(block.timestamp + 1 days));
        _wrap(receipt, SELLER);
        _approveRouter(receipt, SELLER);
        _sell(receipt, SELLER, 10 ether, 9.95 ether);
        _model().finalizeModel(requestId, 98 ether);
        market.release(address(receipt));
        require(market.freeCash() == 90.05 ether, "unused bid still reserved");
        vm.deal(address(queue), 98 ether);
        receipt.claim(1);
        require(
            market.recycle(address(receipt), 10 ether) == 9.8 ether && market.cash() == 99.85 ether,
            "reserve loss accounting"
        );
        vm.prank(SELLER);
        require(receipt.redeem(90 ether, SELLER) == 88.2 ether, "retained actual payout");
    }

    function test_should_bound_prepared_capacity_by_source_nominal_not_zero_receipt_supply() public {
        vm.prank(CURATOR);
        (bool ok,) = address(market)
            .call(
                abi.encodeCall(
                    market.bid, (address(receipt), 101 ether, PRICE, uint64(block.timestamp + 1 days))
                )
            );
        require(!ok && market.totalReserved() == 0, "source amount cap bypass");
        _commit(receipt, 100 ether, uint64(block.timestamp + 1 days));
        require(
            market.totalReserved() == 99.5 ether && receipt.totalSupply() == 0, "valid empty-source capacity"
        );
    }

    function test_should_forbid_curator_repricing_while_empty_bid_is_committed() public {
        _commit(receipt, 20 ether, uint64(block.timestamp + 1 days));
        vm.prank(CURATOR);
        (bool ok,) = address(market)
            .call(
                abi.encodeCall(
                    market.bid, (address(receipt), 20 ether, 0.99 ether, uint64(block.timestamp + 1 days))
                )
            );
        require(!ok, "live prepared bid repriced");
        (uint256 p,, uint256 c,) = market.bids(address(receipt));
        require(p == PRICE && c == 19.9 ether, "commitment changed");
    }

    function test_should_keep_fixed_unit_price_across_sizes_inside_one_live_bid() public {
        _commit(receipt, 20 ether, uint64(block.timestamp + 1 days));
        _wrap(receipt, SELLER);
        require(
            _quote(receipt, 1 ether) == 0.995 ether && _quote(receipt, 10 ether) == 9.95 ether
                && _quote(receipt, 20 ether) == 19.9 ether,
            "size dependent price"
        );
        (, uint256 units, uint256 cash,) = market.bids(address(receipt));
        require(units == 20 ether && cash == 19.9 ether, "quoter consumed bid");
    }

    function test_should_keep_minimum_output_protection_for_a_later_replacement_bid() public {
        _commit(receipt, 20 ether, uint64(block.timestamp + 1 days));
        _wrap(receipt, SELLER);
        _approveRouter(receipt, SELLER);
        uint256 oldQuote = _quote(receipt, 10 ether);
        vm.warp(block.timestamp + 1 days);
        market.release(address(receipt));
        vm.prank(CURATOR);
        market.bid(address(receipt), 20 ether, 0.99 ether, uint64(block.timestamp + 1 days));
        (bool ok,) = address(this).call(abi.encodeCall(this.sale, (receipt, SELLER, 10 ether, oldQuote)));
        require(!ok, "stale minimum ignored");
        require(
            receipt.balanceOf(SELLER) == 100 ether && market.cash() == 100 ether
                && market.totalReserved() == 19.8 ether,
            "stale trade persisted"
        );
    }

    function test_should_isolate_prepared_commitments_across_two_requests_and_expiry_times() public {
        _commit(receipt, 20 ether, uint64(block.timestamp + 1 days));
        _model().create(2, SELLER, 100 ether);
        TunasReceiptCore other = factory.create(2);
        _commit(other, 20 ether, uint64(block.timestamp + 2 days));
        require(market.totalReserved() == 39.8 ether, "cross-request commitment");
        _wrap(receipt, SELLER);
        _approveRouter(receipt, SELLER);
        _sell(receipt, SELLER, 10 ether, 9.95 ether);
        vm.warp(block.timestamp + 1 days);
        market.release(address(receipt));
        require(market.totalReserved() == 19.9 ether && market.cash() == 90.05 ether, "wrong release amount");
        (bool ok,) = address(market).call(abi.encodeCall(market.release, (address(other))));
        require(!ok, "other live quote released");
        require(other.totalSupply() == 0 && queue.ownerOf(2) == SELLER, "other request changed");
    }
}

contract TunasPreparedCanonicalTest is PreparedFixture {
    address private constant CREATE2_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function _deployHook() internal override returns (TunasHook) {
        bytes memory initCode =
            abi.encodePacked(type(TunasHook).creationCode, abi.encode(pm, factory, CURATOR, CAPITAL));
        bytes32 initCodeHash = keccak256(initCode);
        for (uint256 nonce; nonce < 1 << 20; ++nonce) {
            bytes32 salt = bytes32(nonce);
            bytes32 hash = keccak256(abi.encodePacked(hex"ff", CREATE2_PROXY, salt, initCodeHash));
            address predicted = address(uint160(uint256(hash)));
            if (uint160(predicted) & 0x3fff != 0x2a88) continue;

            (bool ok, bytes memory output) = CREATE2_PROXY.call(abi.encodePacked(salt, initCode));
            require(
                ok && address(bytes20(output)) == predicted && predicted.code.length > 0, "CREATE2 failed"
            );
            return TunasHook(predicted);
        }
        revert("No hook salt found");
    }

    function _source() internal override returns (IWithdrawalQueue, uint256) {
        IStETH(STETH).submit{value: 101 ether}(address(0));
        IERC20(STETH).approve(address(LIDO), type(uint256).max);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100 ether;
        return (LIDO, LIDO.requestWithdrawals(amounts, SELLER)[0]);
    }

    function test_should_complete_prefunded_real_request_sale_with_distinct_seller_curator_and_capital_owner()
        public
    {
        _commit(receipt, 20 ether, uint64(block.timestamp + 1 days));
        require(
            receipt.totalSupply() == 0 && queue.ownerOf(requestId) == SELLER
                && market.totalReserved() == 19.9 ether,
            "prefunding/custody"
        );
        (bool ok,) = address(market).call(abi.encodeCall(market.release, (address(receipt))));
        require(!ok, "empty quote lost funding");
        (ok,) = address(this).call(abi.encodeCall(this.quote, (receipt, 10 ether)));
        require(!ok, "canonical empty clone tradable");
        _wrap(receipt, SELLER);
        _approveRouter(receipt, SELLER);
        uint256 out = _quote(receipt, 10 ether);
        require(out == 9.95 ether && _sell(receipt, SELLER, 10 ether, out) == out, "canonical quote/fill");
        require(
            receipt.balanceOf(SELLER) == 90 ether && receipt.balanceOf(CURATOR) == 0
                && receipt.balanceOf(CAPITAL) == 0,
            "wrong retained owner"
        );
        require(market.cash() == 90.05 ether && market.totalReserved() == 9.95 ether, "reserve after fill");
        require(
            pm.balanceOf(address(market), uint256(uint160(address(receipt)))) == 10 ether,
            "acquired claim missing"
        );
        emit log_named_uint("prefunded_canonical_request_id", requestId);
        emit log_named_uint("prefunded_seller_weth_received", out);
        emit log_named_uint("prefunded_retained_receipts", receipt.balanceOf(SELLER));
    }

    function test_measure_seller_stages_after_operator_preparation() public {
        uint256 started;
        uint256 sellerGas;
        vm.prank(CURATOR);
        started = gasleft();
        TunasReceiptCore r = factory.create(requestId);
        emit log_named_uint("operator_receipt_creation_internal_gas", started - gasleft());
        vm.prank(CURATOR);
        started = gasleft();
        market.bid(address(r), 20 ether, PRICE, uint64(block.timestamp + 1 days));
        emit log_named_uint("operator_bid_pool_internal_gas", started - gasleft());
        vm.prank(SELLER);
        started = gasleft();
        queue.approve(address(r), requestId);
        uint256 used = started - gasleft();
        sellerGas += used;
        emit log_named_uint("seller_nft_approve_internal_gas", used);
        vm.prank(SELLER);
        started = gasleft();
        r.wrap();
        used = started - gasleft();
        sellerGas += used;
        emit log_named_uint("seller_wrap_internal_gas", used);
        vm.prank(SELLER);
        started = gasleft();
        r.approve(PERMIT2, type(uint256).max);
        used = started - gasleft();
        sellerGas += used;
        emit log_named_uint("seller_receipt_approve_internal_gas", used);
        vm.prank(SELLER);
        started = gasleft();
        IPermit2(PERMIT2).approve(address(r), ROUTER, type(uint160).max, type(uint48).max);
        used = started - gasleft();
        sellerGas += used;
        emit log_named_uint("seller_permit2_approve_internal_gas", used);
        uint256 quoted = _quote(r, 10 ether);
        started = gasleft();
        uint256 paid = _sell(r, SELLER, 10 ether, quoted);
        used = started - gasleft();
        sellerGas += used;
        emit log_named_uint("seller_router_helper_internal_gas", used);
        require(paid == 9.95 ether && r.balanceOf(SELLER) == 90 ether, "seller stage result");
        emit log_named_uint("seller_stages_total_internal_gas", sellerGas);
    }

    function _campaign(uint256 filled) private {
        require(filled <= 5, "campaign bounds");
        IStETH(STETH).submit{value: 501 ether}(address(0));
        uint256[] memory amounts = new uint256[](5);
        for (uint256 i; i < 5; i++) {
            amounts[i] = 100 ether;
        }
        uint256[] memory ids = LIDO.requestWithdrawals(amounts, SELLER);
        TunasReceiptCore[] memory rs = new TunasReceiptCore[](5);
        uint256 preparationGas;
        uint256 releaseGas;
        uint64 until = uint64(block.timestamp + 1 days);
        for (uint256 i; i < 5; i++) {
            vm.prank(CURATOR);
            uint256 started = gasleft();
            rs[i] = factory.create(ids[i]);
            preparationGas += started - gasleft();
            vm.prank(CURATOR);
            started = gasleft();
            market.bid(address(rs[i]), 10 ether, PRICE, until);
            preparationGas += started - gasleft();
        }
        require(market.totalReserved() == 49.75 ether, "campaign funding");
        for (uint256 i; i < filled; i++) {
            _wrap(rs[i], SELLER);
            _approveRouter(rs[i], SELLER);
            require(_sell(rs[i], SELLER, 10 ether, 9.95 ether) == 9.95 ether, "campaign fill");
        }
        vm.warp(until);
        for (uint256 i = filled; i < 5; i++) {
            uint256 started = gasleft();
            market.release(address(rs[i]));
            releaseGas += started - gasleft();
            require(
                rs[i].totalSupply() == 0 && queue.ownerOf(ids[i]) == SELLER, "unfilled NFT custody changed"
            );
        }
        require(
            market.totalReserved() == 0 && market.cash() == 100 ether - filled * 9.95 ether, "campaign cash"
        );
        emit log_named_uint("campaign_prepared", 5);
        emit log_named_uint("campaign_successful_fills", filled);
        emit log_named_uint("campaign_nominal_units_bought", filled * 10 ether);
        emit log_named_uint("campaign_weth_paid", filled * 9.95 ether);
        emit log_named_uint("campaign_preparation_internal_gas", preparationGas);
        emit log_named_uint("campaign_expired_release_internal_gas", releaseGas);
        emit log_named_uint("campaign_operator_total_internal_gas", preparationGas + releaseGas);
        if (filled > 0) {
            emit log_named_uint(
                "campaign_operator_internal_gas_per_success", (preparationGas + releaseGas) / filled
            );
        }
    }

    function test_measure_preparation_campaign_five_of_five_filled() public {
        _campaign(5);
    }

    function test_measure_preparation_campaign_two_of_five_filled() public {
        _campaign(2);
    }

    function test_measure_preparation_campaign_one_of_five_filled() public {
        _campaign(1);
    }

    function test_measure_preparation_campaign_zero_of_five_filled() public {
        _campaign(0);
    }
}
