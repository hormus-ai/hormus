// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
contract MockERC20 {
    mapping(address=>uint) public balanceOf; mapping(address=>mapping(address=>uint)) public allowance;
    function decimals() external pure returns (uint8) { return 6; }
    function mint(address a,uint v) external { balanceOf[a]+=v; }
    function approve(address s,uint v) external returns(bool){ allowance[msg.sender][s]=v; return true; }
    function transfer(address to,uint v) external returns(bool){ balanceOf[msg.sender]-=v; balanceOf[to]+=v; return true; }
    function transferFrom(address f,address to,uint v) external returns(bool){ allowance[f][msg.sender]-=v; balanceOf[f]-=v; balanceOf[to]+=v; return true; }
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
