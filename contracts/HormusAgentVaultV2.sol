// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title HormusAgentVaultV2
/// @notice User-owned USDG vault where each user lets research agents trade a budget they reserve, under limits they choose.
/// @dev Safety model:
///  - Funds are tracked per user. Only the user can withdraw USDG, release budgets or withdraw agent positions,
///    and those functions keep working while the vault is paused.
///  - Limits are the user's choice: budget, max per order, daily limit, how long auto-trading stays on,
///    and which tokens the agent may buy (owner list, the user's own list, or any token in degen mode).
///  - The executor (a HORMUS backend key) can only call agentBuy / agentSell for agents whose owner switched
///    auto-trading on, only within that agent's max per order, daily limit and budget. Every trade starts and ends
///    in USDG inside this vault: Uniswap v3 (SwapRouter02), Uniswap v4 (PoolManager) or a Pons bonding curve.
///  - Proceeds always come back into the vault under the same user. The executor can never send funds anywhere else.
///  - Worst case if the executor key leaks: the agent budgets users reserved, within their own limits.
interface IERC20Min {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
}

interface IWETH9Min {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

interface ISwapRouter02Min {
    struct ExactInputParams { bytes path; address recipient; uint256 amountIn; uint256 amountOutMinimum; }
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

interface IPonsCurve {
    function token() external view returns (address);
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256 tokensOut);
    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient) external returns (uint256 quoteOut);
}

struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }

interface IPoolManagerMin {
    struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256 delta);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
}

contract HormusAgentVaultV2 {
    IERC20Min public immutable usdg;
    ISwapRouter02Min public immutable router;
    address public immutable weth;
    IPoolManagerMin public immutable poolManager;

    address public owner;
    address public pendingOwner;
    address public executor;
    bool public paused; // pauses deposits, new budgets and agent trades. Never blocks user exits.
    uint256 private entered = 1;

    uint8 public constant ROUTE_V3 = 0;
    uint8 public constant ROUTE_V4 = 1;
    uint8 public constant ROUTE_PONS = 2;
    uint160 private constant MIN_SQRT_PRICE_PLUS_ONE = 4295128740;
    uint160 private constant MAX_SQRT_PRICE_MINUS_ONE = 1461446703485210103287273052203988822378723970341;

    struct Agent {
        uint128 budget;      // USDG still reserved for this agent
        uint128 maxOrder;    // max USDG per agent buy
        uint128 dailyLimit;  // max USDG the agent may spend per UTC day (type(uint128).max = no daily limit)
        uint128 spentToday;  // USDG spent on buys in `day`
        uint64 day;          // UTC day index of spentToday
        uint64 autoUntil;    // auto-trading allowed until this timestamp (0 = off, type(uint64).max = until switched off)
        bool degen;          // true: the agent may buy any token, not only allowlisted ones
    }

    /// @notice How a trade is routed. Every route starts and ends in USDG held by this vault.
    ///  ROUTE_V3:   v3Path is the full SwapRouter02 path USDG→[WETH]→token (or reverse for a sell).
    ///  ROUTE_V4:   key is a v4 pool of the token against USDG, WETH or native ETH. For WETH / ETH pools,
    ///              v3Path is the 1-hop USDG→WETH leg (WETH→USDG for a sell).
    ///  ROUTE_PONS: curve is the token's Pons bonding curve (priced in ETH); v3Path is the USDG↔WETH leg.
    struct Route { uint8 kind; bytes v3Path; PoolKey key; address curve; }

    mapping(address => uint256) public deposited;      // user USDG in the vault (free + reserved)
    mapping(address => uint256) public allocatedTotal; // user USDG reserved for agents
    mapping(address => mapping(bytes32 => Agent)) public agents;
    mapping(address => mapping(bytes32 => mapping(address => uint256))) public positions; // tokens an agent bought
    mapping(address => bool) public tokenAllowed;                        // owner list, for every user
    mapping(address => mapping(address => bool)) public userTokenAllowed; // each user's own list
    mapping(address => uint256) public nonces;                           // for gasless allowlist signatures

    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 public constant ALLOW_TYPEHASH = keccak256("AllowTokens(address user,bytes32 tokensHash,bool allowed,uint256 nonce,uint256 deadline)");

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, address indexed recipient, uint256 amount);
    event Allocated(address indexed user, bytes32 indexed agentId, uint256 budget, uint256 maxOrder, uint256 dailyLimit);
    event Deallocated(address indexed user, bytes32 indexed agentId, uint256 released);
    event AutoTradeSet(address indexed user, bytes32 indexed agentId, uint64 until);
    event AgentModeSet(address indexed user, bytes32 indexed agentId, bool degen);
    event UserTokenAllowed(address indexed user, address indexed token, bool allowed);
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

    constructor(address usdgToken, address swapRouter, address wethToken, address v4PoolManager) {
        require(usdgToken != address(0) && swapRouter != address(0) && wethToken != address(0) && v4PoolManager != address(0), "ZERO_ADDRESS");
        usdg = IERC20Min(usdgToken);
        router = ISwapRouter02Min(swapRouter);
        weth = wethToken;
        poolManager = IPoolManagerMin(v4PoolManager);
        owner = msg.sender;
        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("HormusAgentVaultV2"), keccak256("2"), block.chainid, address(this)));
        emit OwnershipTransferred(address(0), msg.sender);
    }

    /// @dev ETH only arrives in the middle of an agent trade (WETH unwrap, Pons curve, v4 take).
    receive() external payable { require(entered == 2, "NO_DIRECT_ETH"); }

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

    // ---------------- user: agent budgets and settings ----------------
    /// @notice Reserve a budget for an agent. Any limits the user wants; dailyLimit = type(uint128).max means no daily limit.
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

    /// @notice Lets the executor trade this agent's budget until `until` (any future time; type(uint64).max = until
    ///  switched off). 0 switches it off. Works while paused.
    function setAutoTrade(bytes32 agentId, uint64 until) external {
        require(until == 0 || until > block.timestamp, "INVALID_EXPIRY");
        if (until != 0) require(agents[msg.sender][agentId].budget > 0, "NO_BUDGET");
        agents[msg.sender][agentId].autoUntil = until;
        emit AutoTradeSet(msg.sender, agentId, until);
    }

    /// @notice Degen mode: the agent may buy any token, not only allowlisted ones. Limits still apply.
    function setAgentMode(bytes32 agentId, bool degen) external {
        agents[msg.sender][agentId].degen = degen;
        emit AgentModeSet(msg.sender, agentId, degen);
    }

    /// @notice The user's own allowlist: tokens their agents may buy, on top of the owner list.
    function setMyTokens(address[] calldata tokens, bool allowed) external {
        _setUserTokens(msg.sender, tokens, allowed);
    }

    /// @notice Same as setMyTokens, from a gasless EIP-712 signature by the user (used by "Allow & buy").
    function setMyTokensBySig(address user, address[] calldata tokens, bool allowed, uint256 deadline, bytes calldata signature) external {
        require(block.timestamp <= deadline, "SIGNATURE_EXPIRED");
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR,
            keccak256(abi.encode(ALLOW_TYPEHASH, user, keccak256(abi.encodePacked(tokens)), allowed, nonces[user]++, deadline))));
        require(user != address(0) && _recover(digest, signature) == user, "BAD_SIGNATURE");
        _setUserTokens(user, tokens, allowed);
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
    function agentBuy(address user, bytes32 agentId, address token, uint256 amountIn, uint256 minOut, Route calldata r)
        external nonReentrant onlyExecutor whenNotPaused returns (uint256 received)
    {
        require(amountIn > 0 && minOut > 0, "INVALID_AMOUNTS");
        require(token != address(0) && token != address(usdg) && token != weth, "INVALID_TOKEN");
        Agent storage a = agents[user][agentId];
        require(_autoOn(a), "AUTO_TRADE_OFF");
        require(a.degen || tokenAllowed[token] || userTokenAllowed[user][token], "TOKEN_NOT_ALLOWED");
        require(amountIn <= a.maxOrder, "ABOVE_MAX_ORDER");
        require(amountIn <= a.budget, "ABOVE_BUDGET");
        uint64 today = uint64(block.timestamp / 1 days);
        if (a.day != today) { a.day = today; a.spentToday = 0; }
        require(uint256(a.spentToday) + amountIn <= a.dailyLimit, "ABOVE_DAILY_LIMIT");

        a.budget -= uint128(amountIn);
        a.spentToday += uint128(amountIn);
        allocatedTotal[user] -= amountIn;
        deposited[user] -= amountIn;

        uint256 tokenBefore = IERC20Min(token).balanceOf(address(this));
        if (r.kind == ROUTE_V3) {
            _requirePath(r.v3Path, address(usdg), token, true);
            _v3(r.v3Path, address(usdg), amountIn);
        } else if (r.kind == ROUTE_V4) {
            address other = _otherSide(r.key, token);
            if (other == address(usdg)) {
                _v4(r.key, address(usdg), amountIn);
            } else {
                require(other == weth || other == address(0), "INVALID_POOL");
                uint256 wethIn = _usdgToWeth(r.v3Path, amountIn);
                if (other == address(0)) IWETH9Min(weth).withdraw(wethIn);
                _v4(r.key, other, wethIn);
            }
        } else if (r.kind == ROUTE_PONS) {
            _requireCurve(r.curve, token);
            uint256 ethIn = _usdgToWeth(r.v3Path, amountIn);
            IWETH9Min(weth).withdraw(ethIn);
            uint256 ethBefore = address(this).balance;
            IPonsCurve(r.curve).buy{ value: ethIn }(ethIn, minOut, address(this));
            require(ethBefore - address(this).balance == ethIn, "CURVE_REFUND");
        } else revert("INVALID_ROUTE");

        received = IERC20Min(token).balanceOf(address(this)) - tokenBefore;
        require(received >= minOut, "TOO_LITTLE_RECEIVED");
        positions[user][agentId][token] += received;
        emit AgentBought(user, agentId, token, amountIn, received);
    }

    function agentSell(address user, bytes32 agentId, address token, uint256 amountIn, uint256 minOut, Route calldata r)
        external nonReentrant onlyExecutor whenNotPaused returns (uint256 received)
    {
        require(amountIn > 0 && minOut > 0, "INVALID_AMOUNTS");
        require(token != address(usdg) && token != weth, "INVALID_TOKEN");
        Agent storage a = agents[user][agentId];
        require(_autoOn(a), "AUTO_TRADE_OFF");
        uint256 held = positions[user][agentId][token];
        require(held >= amountIn, "INSUFFICIENT_POSITION");
        positions[user][agentId][token] = held - amountIn;

        uint256 usdgBefore = usdg.balanceOf(address(this));
        uint256 tokenBefore = IERC20Min(token).balanceOf(address(this));
        if (r.kind == ROUTE_V3) {
            _requirePath(r.v3Path, token, address(usdg), true);
            _v3(r.v3Path, token, amountIn);
        } else if (r.kind == ROUTE_V4) {
            address other = _otherSide(r.key, token);
            if (other != address(usdg)) {
                require(other == weth || other == address(0), "INVALID_POOL");
                _requirePath(r.v3Path, weth, address(usdg), false);
            }
            uint256 got = _v4(r.key, token, amountIn);
            if (other != address(usdg)) {
                if (other == address(0)) IWETH9Min(weth).deposit{ value: got }();
                _wethToUsdg(r.v3Path, got);
            }
        } else if (r.kind == ROUTE_PONS) {
            _requireCurve(r.curve, token);
            _requirePath(r.v3Path, weth, address(usdg), false);
            uint256 ethBefore = address(this).balance;
            _safeApprove(token, r.curve, amountIn);
            IPonsCurve(r.curve).sell(amountIn, 1, address(this));
            _safeApprove(token, r.curve, 0);
            uint256 ethOut = address(this).balance - ethBefore;
            IWETH9Min(weth).deposit{ value: ethOut }();
            _wethToUsdg(r.v3Path, ethOut);
        } else revert("INVALID_ROUTE");
        require(tokenBefore - IERC20Min(token).balanceOf(address(this)) <= amountIn, "SPENT_TOO_MUCH");

        received = usdg.balanceOf(address(this)) - usdgBefore;
        require(received >= minOut, "TOO_LITTLE_RECEIVED");
        a.budget += uint128(received);
        allocatedTotal[user] += received;
        deposited[user] += received;
        emit AgentSold(user, agentId, token, amountIn, received);
    }

    /// @dev Uniswap v4 callback: swap exact input, pay what the pool asks, take the output into this vault.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager) && entered == 2, "NOT_POOL_MANAGER");
        (PoolKey memory key, bool zeroForOne, uint256 amountIn) = abi.decode(data, (PoolKey, bool, uint256));
        int256 delta = poolManager.swap(key, IPoolManagerMin.SwapParams({
            zeroForOne: zeroForOne, amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE_PLUS_ONE : MAX_SQRT_PRICE_MINUS_ONE }), "");
        int128 d0 = int128(delta >> 128);
        int128 d1 = int128(delta);
        (int128 dIn, int128 dOut) = zeroForOne ? (d0, d1) : (d1, d0);
        require(dIn < 0 && uint256(uint128(-dIn)) == amountIn && dOut > 0, "BAD_V4_DELTA");
        address cIn = zeroForOne ? key.currency0 : key.currency1;
        address cOut = zeroForOne ? key.currency1 : key.currency0;
        if (cIn == address(0)) {
            poolManager.settle{ value: amountIn }();
        } else {
            poolManager.sync(cIn);
            _safeTransfer(cIn, address(poolManager), amountIn);
            poolManager.settle();
        }
        uint256 out = uint256(uint128(dOut));
        poolManager.take(cOut, address(this), out);
        return abi.encode(out);
    }

    // ---------------- owner ----------------
    function setExecutor(address next) external onlyOwner { executor = next; emit ExecutorChanged(next); }
    function setPaused(bool value) external onlyOwner { paused = value; emit PausedChanged(value); }
    function setTokensAllowed(address[] calldata tokens, bool allowed) external onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            require(tokens[i] != address(0) && tokens[i] != address(usdg) && tokens[i] != weth, "INVALID_TOKEN");
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
    /// @notice V1-compatible views so existing wallet UIs keep working.
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
    /// @notice Whether this user's agent may buy `token` right now (ignores budget and limits).
    function canBuy(address user, bytes32 agentId, address token) external view returns (bool) {
        return agents[user][agentId].degen || tokenAllowed[token] || userTokenAllowed[user][token];
    }

    // ---------------- internal ----------------
    function _autoOn(Agent storage a) private view returns (bool) { return a.autoUntil != 0 && a.autoUntil >= block.timestamp; }

    function _setUserTokens(address user, address[] calldata tokens, bool allowed) private {
        for (uint256 i = 0; i < tokens.length; i++) {
            require(tokens[i] != address(0) && tokens[i] != address(usdg) && tokens[i] != weth, "INVALID_TOKEN");
            userTokenAllowed[user][tokens[i]] = allowed;
            emit UserTokenAllowed(user, tokens[i], allowed);
        }
    }

    function _recover(bytes32 digest, bytes calldata sig) private pure returns (address) {
        require(sig.length == 65, "BAD_SIGNATURE");
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        if (v < 27) v += 27;
        require(v == 27 || v == 28, "BAD_SIGNATURE");
        require(uint256(s) <= 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0, "BAD_SIGNATURE");
        address signer = ecrecover(digest, v, r, s);
        require(signer != address(0), "BAD_SIGNATURE");
        return signer;
    }

    /// @dev 1-hop (43 bytes) or, when allowed, 2-hop (66 bytes) Uniswap v3 path whose middle token is WETH.
    function _requirePath(bytes calldata path, address tokenIn, address tokenOut, bool allowTwoHop) private view {
        require(path.length == 43 || (allowTwoHop && path.length == 66), "INVALID_PATH");
        require(address(bytes20(path[0:20])) == tokenIn && address(bytes20(path[path.length - 20:path.length])) == tokenOut, "INVALID_PATH");
        if (path.length == 66) require(address(bytes20(path[23:43])) == weth, "INVALID_HOP");
    }

    function _otherSide(PoolKey calldata key, address token) private pure returns (address) {
        if (key.currency0 == token) return key.currency1;
        require(key.currency1 == token, "INVALID_POOL");
        return key.currency0;
    }

    function _requireCurve(address curve, address token) private view {
        require(curve != address(0) && curve.code.length > 0 && IPonsCurve(curve).token() == token, "INVALID_CURVE");
    }

    function _usdgToWeth(bytes calldata path, uint256 amountIn) private returns (uint256) {
        _requirePath(path, address(usdg), weth, false);
        uint256 before = IERC20Min(weth).balanceOf(address(this));
        _v3(path, address(usdg), amountIn);
        return IERC20Min(weth).balanceOf(address(this)) - before;
    }

    function _wethToUsdg(bytes calldata path, uint256 amountIn) private {
        _requirePath(path, weth, address(usdg), false);
        _v3(path, weth, amountIn);
    }

    function _v3(bytes calldata path, address tokenIn, uint256 amountIn) private {
        uint256 inBefore = IERC20Min(tokenIn).balanceOf(address(this));
        _safeApprove(tokenIn, address(router), amountIn);
        router.exactInput(ISwapRouter02Min.ExactInputParams({ path: path, recipient: address(this), amountIn: amountIn, amountOutMinimum: 0 }));
        _safeApprove(tokenIn, address(router), 0);
        require(inBefore - IERC20Min(tokenIn).balanceOf(address(this)) <= amountIn, "SPENT_TOO_MUCH");
    }

    function _v4(PoolKey calldata key, address currencyIn, uint256 amountIn) private returns (uint256 out) {
        bool zeroForOne = key.currency0 == currencyIn;
        require(zeroForOne || key.currency1 == currencyIn, "INVALID_POOL");
        out = abi.decode(poolManager.unlock(abi.encode(key, zeroForOne, amountIn)), (uint256));
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
