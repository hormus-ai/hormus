// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice User-controlled USDG vault for HORMUS agent capital allocation.
/// @dev Allocations are accounting reservations only. No agent/backend spending or swaps.
interface IERC20Vault {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

contract HormusAgentVault {
    IERC20Vault public immutable usdg;
    address public owner;
    bool public depositsPaused;
    uint256 private entered = 1;

    struct Allocation { uint128 amount; uint128 maxOrder; uint128 dailyLimit; uint64 updatedAt; }
    mapping(address => uint256) public deposited;
    mapping(address => uint256) public allocatedTotal;
    mapping(address => mapping(bytes32 => Allocation)) public allocations;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, address indexed recipient, uint256 amount);
    event Allocated(address indexed user, bytes32 indexed agentId, uint256 amount, uint256 maxOrder, uint256 dailyLimit);
    event Deallocated(address indexed user, bytes32 indexed agentId, uint256 amount);
    event DepositPauseChanged(bool paused);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier nonReentrant() { require(entered == 1, "REENTRANT"); entered = 2; _; entered = 1; }
    modifier onlyOwner() { require(msg.sender == owner, "NOT_OWNER"); _; }

    constructor(address usdgToken) {
        require(usdgToken != address(0), "ZERO_TOKEN");
        usdg = IERC20Vault(usdgToken); owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    function deposit(uint256 amount) external nonReentrant {
        require(!depositsPaused, "DEPOSITS_PAUSED");
        require(amount > 0, "ZERO_AMOUNT");
        uint256 beforeBalance = usdg.balanceOf(address(this));
        _safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = usdg.balanceOf(address(this)) - beforeBalance;
        require(received == amount, "UNEXPECTED_TOKEN_AMOUNT");
        deposited[msg.sender] += received;
        emit Deposited(msg.sender, received);
    }

    function allocate(bytes32 agentId, uint128 amount, uint128 maxOrder, uint128 dailyLimit) external {
        require(!depositsPaused, "ALLOCATIONS_PAUSED");
        require(agentId != bytes32(0) && amount > 0, "INVALID_ALLOCATION");
        require(maxOrder > 0 && maxOrder <= amount && dailyLimit >= maxOrder, "INVALID_LIMITS");
        Allocation storage a = allocations[msg.sender][agentId];
        uint256 nextTotal = allocatedTotal[msg.sender] - a.amount + amount;
        require(nextTotal <= deposited[msg.sender], "INSUFFICIENT_UNALLOCATED");
        allocatedTotal[msg.sender] = nextTotal;
        a.amount = amount; a.maxOrder = maxOrder; a.dailyLimit = dailyLimit; a.updatedAt = uint64(block.timestamp);
        emit Allocated(msg.sender, agentId, amount, maxOrder, dailyLimit);
    }

    function deallocate(bytes32 agentId) external {
        Allocation memory a = allocations[msg.sender][agentId];
        require(a.amount > 0, "NO_ALLOCATION");
        allocatedTotal[msg.sender] -= a.amount; delete allocations[msg.sender][agentId];
        emit Deallocated(msg.sender, agentId, a.amount);
    }

    function withdraw(uint256 amount, address recipient) external nonReentrant {
        require(recipient != address(0) && amount > 0, "INVALID_WITHDRAWAL");
        require(deposited[msg.sender] >= allocatedTotal[msg.sender], "ACCOUNTING_ERROR");
        require(deposited[msg.sender] - allocatedTotal[msg.sender] >= amount, "FUNDS_ALLOCATED");
        deposited[msg.sender] -= amount; _safeTransfer(recipient, amount);
        emit Withdrawn(msg.sender, recipient, amount);
    }

    function availableToAllocate(address user) external view returns (uint256) {
        return deposited[user] - allocatedTotal[user];
    }
    function vaultBalance() external view returns (uint256) { return usdg.balanceOf(address(this)); }
    function tokenDecimals() external view returns (uint8) { return usdg.decimals(); }
    function setDepositsPaused(bool paused) external onlyOwner { depositsPaused = paused; emit DepositPauseChanged(paused); }
    function transferOwnership(address nextOwner) external onlyOwner {
        require(nextOwner != address(0), "ZERO_OWNER");
        emit OwnershipTransferred(owner, nextOwner); owner = nextOwner;
    }

    function _safeTransfer(address to, uint256 value) private {
        (bool ok, bytes memory data) = address(usdg).call(abi.encodeWithSelector(usdg.transfer.selector, to, value));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FAILED");
    }
    function _safeTransferFrom(address from, address to, uint256 value) private {
        (bool ok, bytes memory data) = address(usdg).call(abi.encodeWithSelector(usdg.transferFrom.selector, from, to, value));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FROM_FAILED");
    }
}
