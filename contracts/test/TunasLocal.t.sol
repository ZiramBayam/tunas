// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Vm} from "./helpers/ForkInterfaces.sol";
import {FullReceipt} from "./helpers/FullFactory.sol";
import {TunasReceiptCore} from "../src/TunasReceipt.sol";
import {IWithdrawalQueue, IWETH} from "../src/interfaces/ITunasAssets.sol";

interface IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

contract ModelQueue is IWithdrawalQueue {
    address public immutable controller;
    mapping(uint256 => Status) private requests;
    mapping(uint256 => address) public approvals;
    mapping(uint256 => uint256) public payout;
    uint256 public lastFinalized;

    constructor() {
        controller = msg.sender;
    }

    function create(uint256 id, address owner, uint256 amount) external {
        require(msg.sender == controller && requests[id].owner == address(0), "model create");
        requests[id] = Status(amount, amount, owner, block.timestamp, false, false);
    }

    function finalizeModel(uint256 id, uint256 assets) external {
        require(msg.sender == controller, "model controller");
        requests[id].isFinalized = true;
        payout[id] = assets;
        if (id > lastFinalized) lastFinalized = id;
    }

    function ownerOf(uint256 id) external view returns (address) {
        require(!requests[id].isClaimed, "burned");
        return requests[id].owner;
    }

    function approve(address spender, uint256 id) external {
        require(msg.sender == requests[id].owner, "owner");
        approvals[id] = spender;
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        require(!requests[id].isClaimed && requests[id].owner == from && to != address(0), "NFT state");
        require(msg.sender == from || approvals[id] == msg.sender, "NFT approval");
        requests[id].owner = to;
        delete approvals[id];
        if (to.code.length > 0) {
            require(
                IERC721Receiver(to).onERC721Received(msg.sender, from, id, "")
                    == IERC721Receiver.onERC721Received.selector,
                "receiver"
            );
        }
    }

    function getWithdrawalStatus(uint256[] calldata ids) external view returns (Status[] memory s) {
        s = new Status[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            s[i] = requests[ids[i]];
        }
    }

    function claimWithdrawals(uint256[] calldata ids, uint256[] calldata) external {
        for (uint256 i; i < ids.length; ++i) {
            Status storage s = requests[ids[i]];
            require(s.owner == msg.sender && s.isFinalized && !s.isClaimed, "model unclaimable");
            s.isClaimed = true;
            s.owner = address(0);
            (bool ok,) = msg.sender.call{value: payout[ids[i]]}("");
            require(ok, "ETH delivery");
        }
    }

    function requestWithdrawals(uint256[] calldata, address) external pure returns (uint256[] memory) {
        revert("model only");
    }

    function getLastFinalizedRequestId() external view returns (uint256) {
        return lastFinalized;
    }

    function getLastCheckpointIndex() external pure returns (uint256) {
        return 1;
    }

    function findCheckpointHints(uint256[] calldata ids, uint256, uint256)
        external
        pure
        returns (uint256[] memory hints)
    {
        hints = new uint256[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            hints[i] = 1;
        }
    }
}

contract ModelWETH is IWETH {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 approved = allowance[from][msg.sender];
        if (approved != type(uint256).max) allowance[from][msg.sender] = approved - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract TunasLocalTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant SELLER = address(0x5100);
    address private constant BUYER = address(0xB0B);
    ModelQueue internal q;
    ModelWETH internal w;
    TunasReceiptCore private r;

    function _newReceipt(uint256 id) internal virtual returns (TunasReceiptCore) {
        return new FullReceipt(q, IWETH(address(w)), id);
    }

    function setUp() public virtual {
        q = new ModelQueue();
        w = new ModelWETH();
        q.create(1, SELLER, 100 ether);
        r = _newReceipt(1);
        vm.prank(SELLER);
        q.approve(address(r), 1);
        vm.prank(SELLER);
        r.wrap();
    }

    function _split(uint256 units) private {
        vm.prank(SELLER);
        r.transfer(BUYER, units);
    }

    function _claim(uint256 amount) private {
        q.finalizeModel(1, amount);
        vm.deal(address(q), amount);
        r.claim(1);
    }

    function test_should_issue_exactly_one_fixed_receipt_supply_against_escrowed_request() public {
        require(
            q.ownerOf(1) == address(r) && r.totalSupply() == 100 ether && r.balanceOf(SELLER) == 100 ether,
            "escrow/issuance"
        );
        vm.prank(SELLER);
        (bool ok,) = address(r).call(abi.encodeWithSignature("wrap()"));
        require(!ok, "double issuance");
    }

    function test_should_return_nft_only_to_holder_of_all_receipts() public {
        vm.prank(SELLER);
        r.unwrap(SELLER);
        require(q.ownerOf(1) == SELLER && r.totalSupply() == 0 && r.closed(), "not whole ownership");
    }

    function test_should_not_allow_ninety_percent_holder_or_curator_to_take_whole_nft() public {
        _split(10 ether);
        vm.prank(SELLER);
        (bool ok,) = address(r).call(abi.encodeWithSignature("unwrap(address)", SELLER));
        require(!ok, "90% seized NFT");
        vm.prank(address(0xC0));
        (ok,) = address(r).call(abi.encodeWithSignature("unwrap(address)", address(0xC0)));
        require(!ok, "curator seized NFT");
        require(q.ownerOf(1) == address(r), "lost escrow");
    }

    function test_should_not_treat_unfinalized_claim_as_redeemable_cash() public {
        (bool ok,) = address(r).call(abi.encodeWithSignature("claim(uint256)", 1));
        require(!ok, "premature claim");
        vm.prank(SELLER);
        (ok,) = address(r).call(abi.encodeWithSignature("redeem(uint256,address)", 1 ether, SELLER));
        require(!ok, "premature cash");
    }

    function test_should_split_actual_haircut_proceeds_and_not_nominal_face_value() public {
        _split(10 ether);
        _claim(98 ether);
        vm.prank(SELLER);
        uint256 a = r.redeem(90 ether, SELLER);
        vm.prank(BUYER);
        uint256 b = r.redeem(10 ether, BUYER);
        require(a == 88.2 ether && b == 9.8 ether && a + b == 98 ether, "haircut allocation");
        require(r.totalSupply() == 0 && w.balanceOf(address(r)) == 0, "unredeemed assets");
    }

    function test_should_allow_receipt_burn_after_a_zero_payout_in_the_local_loss_model() public {
        _split(10 ether);
        _claim(0);
        vm.prank(SELLER);
        require(r.redeem(90 ether, SELLER) == 0, "invented seller payout");
        vm.prank(BUYER);
        require(r.redeem(10 ether, BUYER) == 0, "invented buyer payout");
        require(r.settled() && r.totalSupply() == 0, "zero loss did not close");
    }

    function test_should_not_let_one_request_consume_another_request_proceeds() public {
        q.create(2, SELLER, 40 ether);
        TunasReceiptCore other = _newReceipt(2);
        vm.prank(SELLER);
        q.approve(address(other), 2);
        vm.prank(SELLER);
        other.wrap();
        _claim(98 ether);
        vm.prank(SELLER);
        (bool ok,) = address(other).call(abi.encodeWithSignature("redeem(uint256,address)", 40 ether, SELLER));
        require(
            !ok && w.balanceOf(address(r)) == 98 ether && w.balanceOf(address(other)) == 0,
            "cross-request contamination"
        );
    }

    function test_should_preserve_theft_and_burn_rules_after_settlement() public {
        _split(10 ether);
        _claim(100 ether);
        vm.prank(BUYER);
        (bool ok,) = address(r).call(abi.encodeWithSignature("redeem(uint256,address)", 11 ether, BUYER));
        require(!ok, "over redemption");
        (ok,) = address(r).call(abi.encodeWithSignature("claim(uint256)", 1));
        require(!ok, "duplicate claim");
        vm.prank(SELLER);
        r.redeem(90 ether, SELLER);
        vm.prank(BUYER);
        r.redeem(10 ether, BUYER);
        vm.prank(BUYER);
        (ok,) = address(r).call(abi.encodeWithSignature("redeem(uint256,address)", 1, BUYER));
        require(!ok, "double spend");
    }

    function testFuzz_should_conserve_all_realized_payout_for_arbitrary_splits_and_redemption_order(
        uint96 rawUnits,
        uint96 rawPayout,
        bool buyerFirst
    ) public {
        uint256 units = 1 + uint256(rawUnits) % (100 ether - 1);
        uint256 assets = 1 + uint256(rawPayout) % (100 ether);
        _split(units);
        _claim(assets);
        if (buyerFirst) {
            vm.prank(BUYER);
            r.redeem(units, BUYER);
            vm.prank(SELLER);
            r.redeem(100 ether - units, SELLER);
        } else {
            vm.prank(SELLER);
            r.redeem(100 ether - units, SELLER);
            vm.prank(BUYER);
            r.redeem(units, BUYER);
        }
        require(
            w.balanceOf(SELLER) + w.balanceOf(BUYER) == assets && w.balanceOf(address(r)) == 0
                && r.totalSupply() == 0,
            "payout conservation"
        );
    }
}
