// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IWETH, IWithdrawalQueue} from "./interfaces/ITunasAssets.sol";

// Each receipt represents one request's actual payout.
abstract contract TunasReceiptCore {
    string public constant name = "Tunas request receipt";
    string public constant symbol = "tCLAIM";
    uint8 public constant decimals = 18;
    function _queue() internal view virtual returns (IWithdrawalQueue);
    function _weth() internal view virtual returns (IWETH);
    function _requestId() internal view virtual returns (uint256);

    function queue() public view returns (IWithdrawalQueue) {
        return _queue();
    }

    function weth() public view returns (IWETH) {
        return _weth();
    }

    function requestId() public view returns (uint256) {
        return _requestId();
    }
    uint256 public totalSupply;
    uint256 public nominal;
    uint256 public realized;
    bool public wrapped;
    bool public settled;
    bool public closed;
    bool private busy;
    address private expectedFrom;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    modifier lock() {
        require(!busy, "busy");
        busy = true;
        _;
        busy = false;
    }
    receive() external payable {}

    function status() public view returns (IWithdrawalQueue.Status memory) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = requestId();
        return queue().getWithdrawalStatus(ids)[0];
    }

    function pending() public view returns (bool) {
        if (!wrapped || settled || closed) return false;
        IWithdrawalQueue.Status memory s = status();
        return !s.isFinalized && !s.isClaimed && s.owner == address(this);
    }

    function wrap() external lock {
        require(!wrapped && !closed, "one issuance");
        IWithdrawalQueue.Status memory s = status();
        require(!s.isClaimed && s.owner == msg.sender && s.amountOfStETH > 0, "request owner");
        expectedFrom = msg.sender;
        queue().safeTransferFrom(msg.sender, address(this), requestId());
        expectedFrom = address(0);
        require(queue().ownerOf(requestId()) == address(this), "NFT not escrowed");
        wrapped = true;
        nominal = s.amountOfStETH;
        totalSupply = nominal;
        balanceOf[msg.sender] = nominal;
        emit Transfer(address(0), msg.sender, nominal);
    }

    function onERC721Received(address, address from, uint256 id, bytes calldata)
        external
        view
        returns (bytes4)
    {
        require(
            msg.sender == address(queue()) && busy && from == expectedFrom && id == requestId(),
            "unexpected NFT"
        );
        return this.onERC721Received.selector;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(to != address(0), "recipient");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    function unwrap(address to) external lock {
        require(
            wrapped && !closed && !settled && totalSupply > 0 && balanceOf[msg.sender] == totalSupply,
            "all receipts required"
        );
        uint256 units = totalSupply;
        totalSupply = 0;
        balanceOf[msg.sender] = 0;
        closed = true;
        emit Transfer(msg.sender, address(0), units);
        queue().safeTransferFrom(address(this), to, requestId());
    }

    function claim(uint256 hint) external lock returns (uint256 received) {
        require(wrapped && !settled && !closed, "claim state");
        IWithdrawalQueue.Status memory s = status();
        require(s.isFinalized && !s.isClaimed && s.owner == address(this), "not finalized");
        uint256[] memory ids = new uint256[](1);
        ids[0] = requestId();
        uint256[] memory hints = new uint256[](1);
        hints[0] = hint;
        uint256 beforeBalance = address(this).balance;
        queue().claimWithdrawals(ids, hints);
        received = address(this).balance - beforeBalance;
        weth().deposit{value: received}();
        realized = received;
        settled = true;
    }

    function redeem(uint256 units, address to) external lock returns (uint256 assets) {
        require(settled && units > 0 && balanceOf[msg.sender] >= units && to != address(0), "redeem");
        assets = weth().balanceOf(address(this)) * units / totalSupply;
        balanceOf[msg.sender] -= units;
        totalSupply -= units;
        emit Transfer(msg.sender, address(0), units);
        require(weth().transfer(to, assets), "payout");
    }
}

contract TunasReceipt is TunasReceiptCore {
    IWithdrawalQueue private boundQueue;
    IWETH private boundWeth;
    uint256 private boundRequestId;
    bool private initialized;

    constructor() {
        initialized = true;
    }

    function initialize(IWithdrawalQueue q, IWETH w, uint256 id) external {
        require(!initialized, "already initialized");
        require(address(q).code.length > 0 && address(w).code.length > 0 && id > 0, "invalid bindings");
        initialized = true;
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
