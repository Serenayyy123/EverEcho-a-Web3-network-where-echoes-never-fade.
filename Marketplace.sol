// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./EOCHO.sol";
import "./UserRegistry.sol";

contract Marketplace is AccessControl, ReentrancyGuard {
    using SafeERC20 for EOCHO;

    bytes32 public constant DISPUTE_JUDGE = keccak256("DISPUTE_JUDGE");

    EOCHO public immutable token;
    UserRegistry public immutable registry;

    uint256 public exchangeCounter;
    uint256 public helpCounter;

    uint256 public constant DEFAULT_EXCHANGE_STAKE = 20 ether;
    uint256 public constant EXCHANGE_PENDING_SECONDS = 15 days;
    uint256 public constant HELP_MIN_STAKE = 10 ether;
    uint256 public constant HELP_AUTO_COMPLETE_SECONDS = 7 days;

    constructor(EOCHO _token, UserRegistry _registry) {
        token = _token;
        registry = _registry;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(DISPUTE_JUDGE, msg.sender);
    }

    enum TaskState {
        None,
        Pending,
        Matched,
        Delivery,
        Completed,
        Cancelled,
        Disputed
    }

    enum TaskType {
        ExchangeGift,
        EochoHelp
    }

    // ------------------ Exchange Gift ------------------
    struct ExchangeTask {
        uint256 id;
        address creator;
        string city;
        bytes encryptedDeliveryAddress;
        string[] wishList;
        uint256 stake;
        TaskState state;
        uint256 createdAt;
        uint256 expiresAt;
        address partner;
        bool creatorEnteredDelivery;
        bool partnerEnteredDelivery;
        bool creatorConfirmed;
        bool partnerConfirmed;
    }

    mapping(uint256 => ExchangeTask) private exchangeTasks;

    event ExchangeTaskCreated(uint256 id, address creator, string city);
    event ExchangeTaskCancelled(uint256 id, address by);
    event ExchangeTaskMatched(uint256 id, address partner);
    event ExchangeTaskApproved(uint256 id);
    event ExchangeTaskEnteredDelivery(uint256 id, address who, string trackingNumber);
    event ExchangeTaskConfirmed(uint256 id, address who);
    event ExchangeTaskCompleted(uint256 id);
    event ExchangeTaskDisputed(uint256 id, address judge);

    function createExchangeTask(
        string calldata city,
        bytes calldata encryptedDeliveryAddress,
        string[] calldata wishList
    ) external nonReentrant returns (uint256) {

        token.safeTransferFrom(msg.sender, address(this), DEFAULT_EXCHANGE_STAKE);

        exchangeCounter++;
        uint256 id = exchangeCounter;

        ExchangeTask storage t = exchangeTasks[id];
        t.id = id;
        t.creator = msg.sender;
        t.city = city;
        t.encryptedDeliveryAddress = encryptedDeliveryAddress;
        t.stake = DEFAULT_EXCHANGE_STAKE;
        t.state = TaskState.Pending;
        t.createdAt = block.timestamp;
        t.expiresAt = block.timestamp + EXCHANGE_PENDING_SECONDS;

        for (uint i = 0; i < wishList.length; i++) {
            t.wishList.push(wishList[i]);
        }

        emit ExchangeTaskCreated(id, msg.sender, city);
        return id;
    }

    function requestMatch(uint256 id) external nonReentrant {
        ExchangeTask storage t = exchangeTasks[id];

        require(t.state == TaskState.Pending, "Not pending");
        require(block.timestamp <= t.expiresAt, "Expired");
        require(msg.sender != t.creator, "Cannot match self");

        token.safeTransferFrom(msg.sender, address(this), t.stake);
        t.partner = msg.sender;

        emit ExchangeTaskMatched(id, msg.sender);
    }

    function approveMatch(uint256 id) external nonReentrant {
        ExchangeTask storage t = exchangeTasks[id];

        require(msg.sender == t.creator, "Only creator");
        require(t.partner != address(0), "No partner");
        require(t.state == TaskState.Pending, "Wrong state");

        t.state = TaskState.Matched;

        emit ExchangeTaskApproved(id);
    }

    function enterDelivery(uint256 id, string calldata trackingNumber) external nonReentrant {
        ExchangeTask storage t = exchangeTasks[id];

        require(
            t.state == TaskState.Matched || t.state == TaskState.Delivery,
            "Not ready"
        );
        require(
            msg.sender == t.creator || msg.sender == t.partner,
            "Not part"
        );

        t.state = TaskState.Delivery;

        if (msg.sender == t.creator) t.creatorEnteredDelivery = true;
        else t.partnerEnteredDelivery = true;

        emit ExchangeTaskEnteredDelivery(id, msg.sender, trackingNumber);
    }

    function confirmDelivery(uint256 id) external nonReentrant {
        ExchangeTask storage t = exchangeTasks[id];

        require(t.state == TaskState.Delivery, "Not delivery");
        require(msg.sender == t.creator || msg.sender == t.partner, "Not part");

        if (msg.sender == t.creator) t.creatorConfirmed = true;
        else t.partnerConfirmed = true;

        emit ExchangeTaskConfirmed(id, msg.sender);

        if (t.creatorConfirmed && t.partnerConfirmed) {
            t.state = TaskState.Completed;
            token.safeTransfer(t.creator, t.stake);
            token.safeTransfer(t.partner, t.stake);
            emit ExchangeTaskCompleted(id);
        }
    }

    function cancelExchangeTask(uint256 id) external nonReentrant {
        ExchangeTask storage t = exchangeTasks[id];

        require(
            t.state == TaskState.Pending || t.state == TaskState.Matched,
            "Cannot cancel"
        );

        if (t.state == TaskState.Pending) {
            require(msg.sender == t.creator, "Only creator");
            t.state = TaskState.Cancelled;
            token.safeTransfer(t.creator, t.stake);
            emit ExchangeTaskCancelled(id, msg.sender);
            return;
        }

        if (t.state == TaskState.Matched) {
            require(
                !t.creatorEnteredDelivery && !t.partnerEnteredDelivery,
                "In delivery"
            );

            t.state = TaskState.Cancelled;
            token.safeTransfer(t.creator, t.stake);
            token.safeTransfer(t.partner, t.stake);

            emit ExchangeTaskCancelled(id, msg.sender);
            return;
        }
    }

    function resolveDispute(uint256 id, address winner)
        external
        onlyRole(DISPUTE_JUDGE)
        nonReentrant
    {
        ExchangeTask storage t = exchangeTasks[id];

        require(
            t.state == TaskState.Delivery || t.state == TaskState.Disputed,
            "Not disputable"
        );

        t.state = TaskState.Completed;

        token.safeTransfer(winner, t.stake * 2);

        emit ExchangeTaskDisputed(id, msg.sender);
        emit ExchangeTaskCompleted(id);
    }

    // ------------------ Help Task ------------------

    struct HelpTask {
        uint256 id;
        address requester;
        TaskType taskType;
        string details;
        uint256 stake;
        TaskState state;
        address helper;
        uint256 createdAt;
        uint256 expiresAt;
    }

    mapping(uint256 => HelpTask) private helpTasks;

    event HelpTaskCreated(uint256 id, address requester, TaskType ttype);
    event HelpTaskAccepted(uint256 id, address helper);

    function createHelpTask(
        TaskType taskType,
        string calldata details,
        uint256 stake
    ) external nonReentrant returns (uint256) {
        require(stake >= HELP_MIN_STAKE, "Min 10 EOCHO");

        token.safeTransferFrom(msg.sender, address(this), stake);

        helpCounter++;
        uint256 id = helpCounter;

        HelpTask storage h = helpTasks[id];
        h.id = id;
        h.requester = msg.sender;
        h.taskType = taskType;
        h.details = details;
        h.stake = stake;
        h.state = TaskState.Pending;
        h.createdAt = block.timestamp;
        h.expiresAt = block.timestamp + HELP_AUTO_COMPLETE_SECONDS;

        emit HelpTaskCreated(id, msg.sender, taskType);
        return id;
    }

    function acceptHelpTask(uint256 id) external nonReentrant {
        HelpTask storage h = helpTasks[id];

        require(h.state == TaskState.Pending, "Not pending");
        require(block.timestamp <= h.expiresAt, "Expired");
        require(msg.sender != h.requester, "Cannot accept own");

        h.helper = msg.sender;
        h.state = TaskState.Matched;

        emit HelpTaskAccepted(id, msg.sender);
    }

    function completeHelpTask(uint256 id) external nonReentrant {
        HelpTask storage h = helpTasks[id];

        require(h.state == TaskState.Matched, "Not matched");
        require(
            msg.sender == h.helper || block.timestamp >= h.expiresAt,
            "Only helper or timeout"
        );

        h.state = TaskState.Completed;
        token.safeTransfer(h.helper, h.stake);
    }
}
