// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title HormusAgentVaultV2
/// @notice User-owned USDG vault where each user can let a research agent trade a reserved budget.
/// @dev Safety model:
///  - Funds are tracked per user. Only the user can withdraw USDG, release budgets or withdraw agent positions,
///    and those functions keep working while the vault is paused.
///  - The executor (a HORMUS backend key) can only call agentBuy / agentSell, only for agents whose owner switched
///    auto-trading on (with an expiry of at most 30 days), only within the agent's max-per-order, daily limit and budget,
///    only through the Uniswap v3 SwapRouter02 set at deployment, only on USDG→[WETH]→token / token→[WETH]→USDG paths,
///    and only for tokens on the allowlist. Proceeds always come back into the vault under the same user.
///  - The executor can never send funds to any other address.
interface IERC20Min {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
}

interface ISwapRouter02Min {
    struct ExactInputParams { bytes path; address recipient; uint256 amountIn; uint256 amountOutMinimum; }
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

contract HormusAgentVaultV2 {
    IERC20Min public immutable usdg;
    ISwapRouter02Min public immutable router;
    address public immutable weth;

    address public owner;
    address public pendingOwner;
    address public executor;
    bool public paused; // pauses deposits, new budgets and agent trades. Never blocks user exits.
    uint256 private entered = 1;

    uint64 public constant MAX_AUTO_DURATION = 30 days;

    struct Agent {
        uint128 budget;      // USDG still reserved for this agent
        uint128 maxOrder;    // max USDG per agent buy
        uint128 dailyLimit;  // max USDG the agent may spend per UTC day
        uint128 spentToday;  // USDG spent on buys in `day`
        uint64 day;          // UTC day index of spentToday
        uint64 autoUntil;    // auto-trading allowed until this timestamp (0 = off)
    }

    mapping(address => uint256) public deposited;      // user USDG in the vault (free + reserved)
    mapping(address => uint256) public allocatedTotal; // user USDG reserved for agents
    mapping(address => mapping(bytes32 => Agent)) public agents;
    mapping(address => mapping(bytes32 => mapping(address => uint256))) public positions; // tokens an agent bought
    mapping(address => bool) public tokenAllowed;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, address indexed recipient, uint256 amount);
    event Allocated(address indexed user, bytes32 indexed agentId, uint256 budget, uint256 maxOrder, uint256 dailyLimit);
    event Deallocated(address indexed user, bytes32 indexed agentId, uint256 released);
    event AutoTradeSet(address indexed user, bytes32 indexed agentId, uint64 until);
    event AgentBought(address indexed user, bytes32 indexed agentId, address indexed token, uint256 usdgIn, uint256 tokensOut);
    event AgentSold(address indexed user, bytes32 indexed agentId, address indexed token, uint256 tokensIn, uint256 usdgOut);
    event PositionWithdrawn(address indexed user, bytes32 indexed agentId, address indexed token, uint256 amount, address recipient);
    event ExecutorChanged(address indexed executor);
    event PausedChanged(bool paused);
    event TokenAllowed(address indexed token, bool allowed);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier nonReentrant() { require(entered == 1, "REENTRANT"); entered = 2; _; entered = 1; }
    modifier onlyOwner() { require(msg.sender == owner, "NOT_OWNER"); _; }
    modifier onlyExecutor() { require(msg.sender == executor && executor != address(0), "NOT_EXECUTOR"); _; }
    modifier whenNotPaused() { require(!paused, "PAUSED"); _; }

    constructor(address usdgToken, address swapRouter, address wethToken) {
        require(usdgToken != address(0) && swapRouter != address(0) && wethToken != address(0), "ZERO_ADDRESS");
        usdg = IERC20Min(usdgToken);
        router = ISwapRouter02Min(swapRouter);
        weth = wethToken;
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // ---------------- user: USDG ----------------
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "ZERO_AMOUNT");
        uint256 beforeBalance = usdg.balanceOf(address(this));
        _safeTransferFrom(address(usdg), msg.sender, address(this), amount);
        require(usdg.balanceOf(address(this)) - beforeBalance == amount, "UNEXPECTED_TOKEN_AMOUNT");
        deposited[msg.sender] += amount;
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount, address recipient) external nonReentrant {
        require(recipient != address(0) && amount > 0, "INVALID_WITHDRAWAL");
        require(deposited[msg.sender] - allocatedTotal[msg.sender] >= amount, "FUNDS_ALLOCATED");
        deposited[msg.sender] -= amount;
        _safeTransfer(address(usdg), recipient, amount);
        emit Withdrawn(msg.sender, recipient, amount);
    }

    // ---------------- user: agent budgets ----------------
    function allocate(bytes32 agentId, uint128 budget, uint128 maxOrder, uint128 dailyLimit) external whenNotPaused {
        require(agentId != bytes32(0) && budget > 0, "INVALID_ALLOCATION");
        require(maxOrder > 0 && maxOrder <= budget && dailyLimit >= maxOrder, "INVALID_LIMITS");
        Agent storage a = agents[msg.sender][agentId];
        uint256 nextTotal = allocatedTotal[msg.sender] - a.budget + budget;
        require(nextTotal <= deposited[msg.sender], "INSUFFICIENT_UNALLOCATED");
        allocatedTotal[msg.sender] = nextTotal;
        a.budget = budget; a.maxOrder = maxOrder; a.dailyLimit = dailyLimit;
        emit Allocated(msg.sender, agentId, budget, maxOrder, dailyLimit);
    }

    /// @notice Releases the agent's remaining USDG budget and switches auto-trading off. Works while paused.
    function deallocate(bytes32 agentId) external {
        Agent storage a = agents[msg.sender][agentId];
        uint256 released = a.budget;
        allocatedTotal[msg.sender] -= released;
        a.budget = 0; a.autoUntil = 0;
        emit Deallocated(msg.sender, agentId, released);
    }

    /// @notice Lets the executor trade this agent's budget until `until` (max 30 days ahead). 0 switches it off.
    function setAutoTrade(bytes32 agentId, uint64 until) external {
        require(until == 0 || (until > block.timestamp && until <= block.timestamp + MAX_AUTO_DURATION), "INVALID_EXPIRY");
        if (until != 0) require(agents[msg.sender][agentId].budget > 0, "NO_BUDGET");
        agents[msg.sender][agentId].autoUntil = until;
        emit AutoTradeSet(msg.sender, agentId, until);
    }

    /// @notice Sends tokens an agent bought to the user. Works while paused.
    function withdrawPosition(bytes32 agentId, address token, uint256 amount, address recipient) external nonReentrant {
        require(recipient != address(0) && amount > 0, "INVALID_WITHDRAWAL");
        uint256 held = positions[msg.sender][agentId][token];
        require(held >= amount, "INSUFFICIENT_POSITION");
        positions[msg.sender][agentId][token] = held - amount;
        _safeTransfer(token, recipient, amount);
        emit PositionWithdrawn(msg.sender, agentId, token, amount, recipient);
    }

    // ---------------- executor: agent trades ----------------
    function agentBuy(address user, bytes32 agentId, bytes calldata path, uint256 amountIn, uint256 minOut)
        external nonReentrant onlyExecutor whenNotPaused returns (uint256 received)
    {
        require(amountIn > 0 && minOut > 0, "INVALID_AMOUNTS");
        (address tokenIn, address tokenOut) = _checkPath(path);
        require(tokenIn == address(usdg) && tokenOut != address(usdg) && tokenAllowed[tokenOut], "PATH_NOT_ALLOWED");
        Agent storage a = agents[user][agentId];
        require(a.autoUntil != 0 && a.autoUntil >= block.timestamp, "AUTO_TRADE_OFF");
        require(amountIn <= a.maxOrder, "ABOVE_MAX_ORDER");
        require(amountIn <= a.budget, "ABOVE_BUDGET");
        uint64 today = uint64(block.timestamp / 1 days);
        if (a.day != today) { a.day = today; a.spentToday = 0; }
        require(uint256(a.spentToday) + amountIn <= a.dailyLimit, "ABOVE_DAILY_LIMIT");

        a.budget -= uint128(amountIn);
        a.spentToday += uint128(amountIn);
        allocatedTotal[user] -= amountIn;
        deposited[user] -= amountIn;

        received = _swap(path, address(usdg), tokenOut, amountIn, minOut);
        positions[user][agentId][tokenOut] += received;
        emit AgentBought(user, agentId, tokenOut, amountIn, received);
    }

    function agentSell(address user, bytes32 agentId, bytes calldata path, uint256 amountIn, uint256 minOut)
        external nonReentrant onlyExecutor whenNotPaused returns (uint256 received)
    {
        require(amountIn > 0 && minOut > 0, "INVALID_AMOUNTS");
        (address tokenIn, address tokenOut) = _checkPath(path);
        require(tokenOut == address(usdg) && tokenIn != address(usdg), "PATH_NOT_ALLOWED");
        Agent storage a = agents[user][agentId];
        require(a.autoUntil != 0 && a.autoUntil >= block.timestamp, "AUTO_TRADE_OFF");
        uint256 held = positions[user][agentId][tokenIn];
        require(held >= amountIn, "INSUFFICIENT_POSITION");
        positions[user][agentId][tokenIn] = held - amountIn;

        received = _swap(path, tokenIn, address(usdg), amountIn, minOut);
        a.budget += uint128(received);
        allocatedTotal[user] += received;
        deposited[user] += received;
        emit AgentSold(user, agentId, tokenIn, amountIn, received);
    }

    // ---------------- owner ----------------
    function setExecutor(address next) external onlyOwner { executor = next; emit ExecutorChanged(next); }
    function setPaused(bool value) external onlyOwner { paused = value; emit PausedChanged(value); }
    function setTokensAllowed(address[] calldata tokens, bool allowed) external onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            require(tokens[i] != address(0) && tokens[i] != address(usdg), "INVALID_TOKEN");
            tokenAllowed[tokens[i]] = allowed;
            emit TokenAllowed(tokens[i], allowed);
        }
    }
    function transferOwnership(address next) external onlyOwner { pendingOwner = next; emit OwnershipTransferStarted(owner, next); }
    function acceptOwnership() external {
        require(msg.sender == pendingOwner && pendingOwner != address(0), "NOT_PENDING_OWNER");
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner; pendingOwner = address(0);
    }

    // ---------------- views ----------------
    function availableToAllocate(address user) external view returns (uint256) { return deposited[user] - allocatedTotal[user]; }
    /// @notice V1-compatible views so existing wallet UIs keep working after the switch.
    function depositsPaused() external view returns (bool) { return paused; }
    function allocations(address user, bytes32 agentId) external view returns (uint128 amount, uint128 maxOrder, uint128 dailyLimit, uint64 autoUntil) {
        Agent storage a = agents[user][agentId];
        return (a.budget, a.maxOrder, a.dailyLimit, a.autoUntil);
    }
    function vaultBalance() external view returns (uint256) { return usdg.balanceOf(address(this)); }
    function agentState(address user, bytes32 agentId) external view returns (Agent memory a, uint256 spentTodayNow) {
        a = agents[user][agentId];
        spentTodayNow = a.day == uint64(block.timestamp / 1 days) ? a.spentToday : 0;
    }

    // ---------------- internal ----------------
    /// @dev Accepts 1-hop (43 bytes) or 2-hop (66 bytes) Uniswap v3 paths. A middle token must be WETH.
    function _checkPath(bytes calldata path) private view returns (address tokenIn, address tokenOut) {
        require(path.length == 43 || path.length == 66, "INVALID_PATH");
        tokenIn = address(bytes20(path[0:20]));
        tokenOut = address(bytes20(path[path.length - 20:path.length]));
        if (path.length == 66) require(address(bytes20(path[23:43])) == weth, "INVALID_HOP");
        require(tokenIn != tokenOut, "INVALID_PATH");
    }

    function _swap(bytes calldata path, address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut) private returns (uint256 received) {
        uint256 outBefore = IERC20Min(tokenOut).balanceOf(address(this));
        uint256 inBefore = IERC20Min(tokenIn).balanceOf(address(this));
        _safeApprove(tokenIn, address(router), amountIn);
        router.exactInput(ISwapRouter02Min.ExactInputParams({ path: path, recipient: address(this), amountIn: amountIn, amountOutMinimum: minOut }));
        _safeApprove(tokenIn, address(router), 0);
        require(inBefore - IERC20Min(tokenIn).balanceOf(address(this)) <= amountIn, "SPENT_TOO_MUCH");
        received = IERC20Min(tokenOut).balanceOf(address(this)) - outBefore;
        require(received >= minOut, "TOO_LITTLE_RECEIVED");
    }

    function _safeTransfer(address token, address to, uint256 value) private {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20Min.transfer.selector, to, value));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FAILED");
    }
    function _safeTransferFrom(address token, address from, address to, uint256 value) private {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20Min.transferFrom.selector, from, to, value));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FROM_FAILED");
    }
    function _safeApprove(address token, address spender, uint256 value) private {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20Min.approve.selector, spender, value));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "APPROVE_FAILED");
    }
}
