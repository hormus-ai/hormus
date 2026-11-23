// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
// Test doubles for HormusAgentVaultV2. They are simple on purpose: fixed exchange rates, plus switches that
// make them misbehave so the vault's own checks can be tested.

contract MockERC20 {
    mapping(address=>uint) public balanceOf; mapping(address=>mapping(address=>uint)) public allowance;
    function decimals() external pure returns (uint8) { return 6; }
    function mint(address a,uint v) external { balanceOf[a]+=v; }
    function approve(address s,uint v) external returns(bool){ allowance[msg.sender][s]=v; return true; }
    function transfer(address to,uint v) external returns(bool){ balanceOf[msg.sender]-=v; balanceOf[to]+=v; return true; }
    function transferFrom(address f,address to,uint v) external returns(bool){ allowance[f][msg.sender]-=v; balanceOf[f]-=v; balanceOf[to]+=v; return true; }
}

// WETH: 1:1 with ETH. Pre-fund it with ETH (fund()) because the mock router mints WETH without ETH backing.
contract MockWETH is MockERC20 {
    function fund() external payable {}
    function deposit() external payable { this.mint(msg.sender, msg.value); }
    function withdraw(uint v) external { balanceOf[msg.sender]-=v; (bool ok,)=msg.sender.call{value:v}(""); require(ok,"ETH_SEND"); }
}

// Pays out `rateNum/rateDen` of the input in the last token of the path. Pulls the first token.
contract MockRouter02 {
    struct ExactInputParams { bytes path; address recipient; uint256 amountIn; uint256 amountOutMinimum; }
    uint public rateNum = 2; uint public rateDen = 1; bool public steal;
    function setRate(uint n,uint d) external { rateNum=n; rateDen=d; }
    function setSteal(bool s) external { steal=s; }
    function exactInput(ExactInputParams calldata p) external payable returns (uint256 out) {
        address tokenIn = address(bytes20(p.path[0:20]));
        address tokenOut = address(bytes20(p.path[p.path.length-20:p.path.length]));
        MockERC20(tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        out = p.amountIn * rateNum / rateDen;
        require(out >= p.amountOutMinimum, "Too little received");
        MockERC20(tokenOut).mint(steal ? address(0xBEEF) : p.recipient, out);
    }
}

interface IUnlockCallback { function unlockCallback(bytes calldata data) external returns (bytes memory); }
struct MPoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }

// Uniswap v4 PoolManager double: flash accounting per currency; every delta must be zero when unlock ends.
contract MockPoolManager {
    struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }
    uint public rateNum = 3; uint public rateDen = 1; bool public greedy; // greedy: asks for more input than specified
    address locker; address synced; uint syncedBal;
    mapping(address=>int256) public owed; address[] touched;
    function fund() external payable {}
    function setRate(uint n,uint d) external { rateNum=n; rateDen=d; }
    function setGreedy(bool g) external { greedy=g; }
    function _bal(address c) internal view returns (uint) { return c==address(0) ? address(this).balance : MockERC20(c).balanceOf(address(this)); }
    function unlock(bytes calldata data) external returns (bytes memory r) {
        locker = msg.sender;
        r = IUnlockCallback(msg.sender).unlockCallback(data);
        for (uint i=0;i<touched.length;i++) require(owed[touched[i]]==0, "CurrencyNotSettled");
        delete touched; locker = address(0);
    }
    function swap(MPoolKey memory key, SwapParams memory p, bytes calldata) external returns (int256 d) {
        require(msg.sender==locker, "NOT_LOCKED");
        uint amtIn = uint(-p.amountSpecified) + (greedy ? 1 : 0); uint out = (amtIn - (greedy ? 1 : 0)) * rateNum / rateDen;
        address cin = p.zeroForOne ? key.currency0 : key.currency1; address cout = p.zeroForOne ? key.currency1 : key.currency0;
        owed[cin] -= int(amtIn); owed[cout] += int(out); touched.push(cin); touched.push(cout);
        int128 dIn = -int128(int(amtIn)); int128 dOut = int128(int(out));
        (int128 d0, int128 d1) = p.zeroForOne ? (dIn, dOut) : (dOut, dIn);
        d = int256((uint256(uint128(d0)) << 128) | uint256(uint128(d1)));
    }
    function sync(address c) external { synced = c; syncedBal = _bal(c); }
    function settle() external payable returns (uint paid) {
        if (synced == address(0)) paid = msg.value; else { paid = _bal(synced) - syncedBal; }
        owed[synced] += int(paid); synced = address(0);
    }
    function take(address c, address to, uint amt) external {
        owed[c] -= int(amt);
        if (c == address(0)) { (bool ok,)=to.call{value:amt}(""); require(ok,"ETH_SEND"); } else MockERC20(c).mint(to, amt);
    }
}

// Pons bonding curve double: priced in ETH. `refund` sends half of the ETH back on buy.
contract MockPonsCurve {
    address public token; uint public buyRate = 1000; uint public sellDiv = 1000; bool public refund;
    constructor(address t) { token = t; }
    function fund() external payable {}
    function setRefund(bool r) external { refund = r; }
    function buy(uint quoteIn, uint minOut, address recipient) external payable returns (uint out) {
        require(msg.value == quoteIn, "VALUE");
        out = quoteIn * buyRate; require(out >= minOut, "SLIPPAGE");
        MockERC20(token).mint(recipient, out);
        if (refund) { (bool ok,)=msg.sender.call{value:quoteIn/2}(""); require(ok); }
    }
    function sell(uint tokensIn, uint minOut, address recipient) external returns (uint out) {
        MockERC20(token).transferFrom(msg.sender, address(this), tokensIn);
        out = tokensIn / sellDiv; require(out >= minOut, "SLIPPAGE");
        (bool ok,)=recipient.call{value:out}(""); require(ok, "ETH_SEND");
    }
}
