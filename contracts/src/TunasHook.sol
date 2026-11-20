// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ITunasFactory} from "./TunasFactory.sol";
import {TunasReceiptCore} from "./TunasReceipt.sol";
import {IERC20, IWETH, IWithdrawalQueue} from "./interfaces/ITunasAssets.sol";
import {IV4PoolManager, PoolKey, ModifyLiquidityParams, SwapParams} from "./interfaces/IV4PoolManager.sol";

contract TunasHook {
    struct Bid {
        uint256 price;
        uint256 remaining;
        uint256 cash;
        uint64 until;
    }
    enum ActionKind {
        Fund,
        Withdraw,
        Sell,
        Recycle
    }

    struct Action {
        ActionKind kind;
        address payer;
        address receipt;
        uint256 amount;
        address recipient;
        uint256 minimum;
    }
    IV4PoolManager public immutable manager;
    ITunasFactory public immutable factory;
    IWETH public immutable weth;
    address public immutable curator;
    address public immutable capitalOwner;
    uint256 public totalReserved;
    mapping(address => Bid) public bids;
    mapping(bytes32 => address) public receiptForPool;
    mapping(address => bool) public poolCreated;
    event BidCommitted(address indexed receipt, uint256 units, uint256 price, uint256 cash, uint64 until);
    event BidFilled(address indexed receipt, uint256 units, uint256 wethOutput);
    event BidReleased(address indexed receipt, uint256 unusedCash);

    bool private busy;
    modifier lock() {
        require(!busy, "busy");
        busy = true;
        _;
        busy = false;
    }

    constructor(IV4PoolManager pm, ITunasFactory f, address c, address lp) {
        manager = pm;
        factory = f;
        weth = f.weth();
        curator = c;
        capitalOwner = lp;
    }

    function cash() public view returns (uint256) {
        return manager.balanceOf(address(this), uint256(uint160(address(weth))));
    }

    function freeCash() public view returns (uint256) {
        return cash() - totalReserved;
    }

    function keyFor(address receipt) public view returns (PoolKey memory) {
        (address a, address b) = receipt < address(weth) ? (receipt, address(weth)) : (address(weth), receipt);
        return PoolKey(a, b, 0, 1, address(this));
    }

    function fund(uint256 amount) external lock {
        require(msg.sender == capitalOwner && amount > 0, "capital owner");
        manager.unlock(abi.encode(Action(ActionKind.Fund, msg.sender, address(0), amount, address(0), 0)));
    }

    function withdrawCash(uint256 amount, address to) external lock {
        require(msg.sender == capitalOwner && amount <= freeCash() && to != address(0), "cash reserved");
        manager.unlock(abi.encode(Action(ActionKind.Withdraw, address(0), address(0), amount, to, 0)));
    }

    function _pendingSource(address receipt) private view returns (bool valid, uint256 nominalAmount) {
        if (!factory.created(receipt)) return (false, 0);
        TunasReceiptCore r = TunasReceiptCore(payable(receipt));
        if (r.closed() || r.settled()) return (false, 0);
        IWithdrawalQueue.Status memory s = r.status();
        if (s.isFinalized || s.isClaimed || s.owner == address(0) || s.amountOfStETH == 0) return (false, 0);
        if (r.wrapped()) valid = s.owner == receipt && r.nominal() == s.amountOfStETH && r.totalSupply() > 0;
        else valid = s.owner != receipt && r.totalSupply() == 0;
        return (valid, s.amountOfStETH);
    }

    function bid(address receipt, uint256 units, uint256 price, uint64 until)
        external
        lock
        returns (PoolKey memory k)
    {
        require(msg.sender == curator, "curator");
        (bool valid, uint256 sourceNominal) = _pendingSource(receipt);
        require(valid, "curated pending receipt");
        require(units > 0 && units <= sourceNominal && price > 0 && price <= 1 ether, "bid bounds");
        require(until > block.timestamp && until <= block.timestamp + 14 days, "expiry");
        require(bids[receipt].cash == 0, "existing commitment");
        uint256 reserve = (units * price + 1 ether - 1) / 1 ether;
        require(reserve <= freeCash(), "unfunded bid");
        totalReserved += reserve;
        bids[receipt] = Bid(price, units, reserve, until);
        k = keyFor(receipt);
        if (!poolCreated[receipt]) {
            bytes32 id = keccak256(abi.encode(k));
            receiptForPool[id] = receipt;
            poolCreated[receipt] = true;
            manager.initialize(k, uint160(1 << 96));
        }
        emit BidCommitted(receipt, units, price, reserve, until);
    }

    function release(address receipt) external lock {
        Bid storage b = bids[receipt];
        require(factory.created(receipt) && b.until != 0, "unknown bid");
        if (block.timestamp < b.until) {
            (bool valid,) = _pendingSource(receipt);
            require(!valid, "live commitment");
        }
        uint256 unusedCash = b.cash;
        totalReserved -= unusedCash;
        b.cash = 0;
        b.remaining = 0;
        emit BidReleased(receipt, unusedCash);
    }

    function _fill(address receipt, uint256 units, uint256 minimum) private returns (uint256 output) {
        Bid storage b = bids[receipt];
        require(TunasReceiptCore(payable(receipt)).pending() && block.timestamp < b.until, "inactive bid");
        require(units > 0 && units <= b.remaining, "bid capacity");
        output = units * b.price / 1 ether;
        require(output > 0 && output >= minimum && output <= b.cash, "price/minimum");
        b.remaining -= units;
        b.cash -= output;
        totalReserved -= output;
        if (b.remaining == 0) {
            totalReserved -= b.cash;
            b.cash = 0;
        }
        emit BidFilled(receipt, units, output);
    }

    function sellDirect(address receipt, uint256 units, uint256 minimum, address to)
        external
        lock
        returns (uint256)
    {
        require(factory.created(receipt) && to != address(0), "receipt/recipient");
        return abi.decode(
            manager.unlock(abi.encode(Action(ActionKind.Sell, msg.sender, receipt, units, to, minimum))),
            (uint256)
        );
    }

    function recycle(address receipt, uint256 units) external lock returns (uint256) {
        require(factory.created(receipt) && TunasReceiptCore(payable(receipt)).settled(), "not cash");
        return abi.decode(
            manager.unlock(abi.encode(Action(ActionKind.Recycle, address(0), receipt, units, address(0), 0))),
            (uint256)
        );
    }

    function _deposit(address token, address payer, uint256 amount) private {
        manager.mint(address(this), uint256(uint160(token)), amount);
        manager.sync(token);
        require(IERC20(token).transferFrom(payer, address(manager), amount), "transfer input");
        require(manager.settle() == amount, "settlement");
    }

    function _take(address token, uint256 amount, address to) private {
        manager.burn(address(this), uint256(uint160(token)), amount);
        manager.take(token, to, amount);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager) && busy, "callback");
        Action memory a = abi.decode(data, (Action));
        if (a.kind == ActionKind.Fund) {
            _deposit(address(weth), a.payer, a.amount);
            return "";
        }
        if (a.kind == ActionKind.Withdraw) {
            _take(address(weth), a.amount, a.recipient);
            return "";
        }
        if (a.kind == ActionKind.Sell) {
            uint256 saleOutput = _fill(a.receipt, a.amount, a.minimum);
            _deposit(a.receipt, a.payer, a.amount);
            _take(address(weth), saleOutput, a.recipient);
            return abi.encode(saleOutput);
        }
        require(a.kind == ActionKind.Recycle, "action");
        _take(a.receipt, a.amount, address(this));
        uint256 out = TunasReceiptCore(payable(a.receipt)).redeem(a.amount, address(this));
        manager.mint(address(this), uint256(uint160(address(weth))), out);
        manager.sync(address(weth));
        require(weth.transfer(address(manager), out), "recycle transfer");
        require(manager.settle() == out, "recycle settle");
        return abi.encode(out);
    }

    function beforeInitialize(address sender, PoolKey calldata k, uint160) external view returns (bytes4) {
        require(
            msg.sender == address(manager) && sender == address(this)
                && receiptForPool[keccak256(abi.encode(k))] != address(0),
            "initialize"
        );
        return this.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata k, SwapParams calldata p, bytes calldata)
        external
        lock
        returns (bytes4, int256, uint24)
    {
        require(msg.sender == address(manager) && p.amountSpecified < 0, "manager/exact input");
        address receipt = receiptForPool[keccak256(abi.encode(k))];
        require(receipt != address(0), "pool");
        require((p.zeroForOne ? k.currency0 : k.currency1) == receipt, "receipt sale only");
        uint256 input = uint256(-p.amountSpecified);
        uint256 output = _fill(receipt, input, 0);
        require(
            input <= uint256(uint128(type(int128).max)) && output <= uint256(uint128(type(int128).max)),
            "delta bounds"
        );
        // The router settles the receipt input in the same unlock.
        manager.mint(address(this), uint256(uint160(receipt)), input);
        manager.burn(address(this), uint256(uint160(address(weth))), output);
        int256 delta = (int256(input) << 128) | int256(uint256(uint128(-int128(int256(output)))));
        return (this.beforeSwap.selector, delta, 0);
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert("fund reserve");
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert("fund reserve");
    }
}
