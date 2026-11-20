// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IPermit2} from "./helpers/ForkInterfaces.sol";
import {PreparedFixture} from "./TunasPrepared.t.sol";

contract TunasExecutionForkTest is PreparedFixture {
    event BidCommitted(address indexed receipt, uint256 units, uint256 price, uint256 cash, uint64 until);
    event BidFilled(address indexed receipt, uint256 units, uint256 wethOutput);
    event BidReleased(address indexed receipt, uint256 unusedCash);

    function test_bid_events_match_commitment_fill_and_release() public {
        uint64 until = uint64(block.timestamp + 1 days);
        vm.expectEmit(true, false, false, true, address(market));
        emit BidCommitted(address(receipt), 20 ether, 0.995 ether, 19.9 ether, until);
        _commit(receipt, 20 ether, until);
        (uint256 price, uint256 capacity, uint256 committed, uint64 expiry) = market.bids(address(receipt));
        require(
            price == PRICE && capacity == 20 ether && committed == 19.9 ether && expiry == until
                && market.totalReserved() == committed,
            "wrong commitment"
        );

        _wrap(receipt, SELLER);
        _approveRouter(receipt, SELLER);
        vm.expectEmit(true, false, false, true, address(market));
        emit BidFilled(address(receipt), 10 ether, 9.95 ether);
        require(this.sale(receipt, SELLER, 10 ether, 9.95 ether) == 9.95 ether, "wrong seller transfer");
        (, capacity, committed,) = market.bids(address(receipt));
        require(capacity == 10 ether && committed == 9.95 ether, "wrong remaining capacity");
        require(market.cash() == 90.05 ether && market.totalReserved() == committed, "wrong reserve");
        require(pm.balanceOf(address(market), uint160(address(receipt))) == 10 ether, "wrong inventory");

        vm.warp(until);
        vm.expectEmit(true, false, false, true, address(market));
        emit BidReleased(address(receipt), 9.95 ether);
        market.release(address(receipt));
        (, capacity, committed,) = market.bids(address(receipt));
        require(capacity == 0 && committed == 0 && market.totalReserved() == 0, "release incomplete");
        require(
            market.freeCash() == 90.05 ether && receipt.balanceOf(SELLER) == 90 ether,
            "release changed rights"
        );
    }

    function test_failed_input_settlement_rolls_back_the_fill() public {
        _commit(receipt, 20 ether, uint64(block.timestamp + 1 days));
        _wrap(receipt, SELLER);
        vm.prank(SELLER);
        IPermit2(PERMIT2).approve(address(receipt), ROUTER, 10 ether, type(uint48).max);
        uint256 sellerWeth = weth.balanceOf(SELLER);
        require(_quote(receipt, 10 ether) == 9.95 ether, "invalid quote");

        vm.expectCall(address(receipt), abi.encodeCall(receipt.transferFrom, (SELLER, address(pm), 10 ether)));
        vm.expectRevert();
        this.sale(receipt, SELLER, 10 ether, 9.95 ether);

        (, uint256 capacity, uint256 committed,) = market.bids(address(receipt));
        require(capacity == 20 ether && committed == 19.9 ether, "bid changed");
        require(market.totalReserved() == 19.9 ether && market.cash() == 100 ether, "cash changed");
        require(pm.balanceOf(address(market), uint160(address(receipt))) == 0, "inventory changed");
        require(
            weth.balanceOf(SELLER) == sellerWeth && receipt.balanceOf(SELLER) == 100 ether, "seller changed"
        );
        require(
            receipt.totalSupply() == 100 ether && queue.ownerOf(requestId) == address(receipt),
            "custody changed"
        );
    }

    function test_replacement_bid_can_fill_at_the_original_deadline() public {
        uint64 until = _fundReplacementBid();
        vm.warp(until - 1);

        require(_sellWithDeadline(receipt, SELLER, 10 ether, 9.95 ether, until - 1) == 10 ether, "no fill");
        require(receipt.balanceOf(SELLER) == 80 ether, "wrong retained rights");
    }

    function test_replacement_bid_cannot_fill_after_the_original_deadline() public {
        uint64 until = _fundReplacementBid();
        vm.warp(until);

        vm.expectRevert(bytes4(keccak256("TransactionDeadlinePassed()")));
        this.sellWithDeadlineForSeller(until - 1);
        require(receipt.balanceOf(SELLER) == 90 ether && market.totalReserved() == 20 ether, "late fill");
    }

    function sellWithDeadlineForSeller(uint256 deadline) external {
        _sellWithDeadline(receipt, SELLER, 10 ether, 9.95 ether, deadline);
    }

    function _fundReplacementBid() private returns (uint64 originalExpiry) {
        originalExpiry = uint64(block.timestamp + 1 days);
        _commit(receipt, 10 ether, originalExpiry);
        _wrap(receipt, SELLER);
        _approveRouter(receipt, SELLER);
        require(_quote(receipt, 10 ether) == 9.95 ether, "wrong initial quote");
        vm.prank(SELLER);
        receipt.transfer(NEW_OWNER, 10 ether);
        _approveRouter(receipt, NEW_OWNER);
        require(_sell(receipt, NEW_OWNER, 10 ether, 9.95 ether) == 9.95 ether, "bid still live");

        vm.prank(CURATOR);
        market.bid(address(receipt), 20 ether, 1 ether, uint64(block.timestamp + 2 days));
    }
}
