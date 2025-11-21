// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

// =========================================================================
// 0. Interface Definition
// =========================================================================
interface IEOCHOToken is IERC20 {
    function mint(address to, uint256 amount) external;
    function INITIAL_AIRDROP_AMOUNT() external view returns (uint256);
}

// =========================================================================
// 1. EOCHOToken - ERC20代币合约
// =========================================================================
contract EOCHOToken is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    uint256 public constant INITIAL_AIRDROP_AMOUNT = 100 ether; 

    constructor(address initialAdmin) 
        ERC20("EverEcho Coin", "EOCHO") 
    {
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
    }

    function grantMinterRole(address minter) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(MINTER_ROLE, minter);
    }

    function mint(address to, uint256 amount) public {
        require(hasRole(MINTER_ROLE, _msgSender()), "EOCHO: Must have minter role");
        _mint(to, amount);
    }
}

// =========================================================================
// 2. EverEchoCore - 核心逻辑合约
// =========================================================================
contract EverEchoCore is Initializable, Ownable, ReentrancyGuard {
    IEOCHOToken public eochoToken;
    address public exchangeGiftContract;
    address public eochoHelpContract;

    struct UserInfo {
        string nickname;
        string city;
        string tags;
        uint64 registeredAt; 
    }

    mapping(address => UserInfo) public userInfos;
    mapping(address => bool) public isWhitelisted;

    event UserRegistered(address indexed user, string nickname, string city, string tags);
    event InitialAirdrop(address indexed user, uint256 amount);
    event UserInfoUpdated(address indexed user, string nickname, string city, string tags);

    address public coordinator; 

    constructor() Ownable(msg.sender) {}

    modifier onlyCoordinator() {
        require(_msgSender() == coordinator, "EverEchoCore: Not coordinator");
        _;
    }

    function initialize(address _tokenAddress, address _owner) public initializer {
        _transferOwnership(_owner);
        eochoToken = IEOCHOToken(_tokenAddress);
        coordinator = _owner; 
    }

    function ensureRegistered(address user) external {
        if (!isWhitelisted[user]) {
            isWhitelisted[user] = true;
            userInfos[user] = UserInfo({
                nickname: "New User",
                city: "Unknown",
                tags: "Newbie",
                registeredAt: uint64(block.timestamp)
            });
            emit UserRegistered(user, "New User", "Unknown", "Newbie");

            uint256 amount = eochoToken.INITIAL_AIRDROP_AMOUNT();
            eochoToken.mint(user, amount);
            emit InitialAirdrop(user, amount);
        }
    }

    function updateUserInfo(string memory _nickname, string memory _city, string memory _tags) public {
        this.ensureRegistered(_msgSender());
        
        userInfos[_msgSender()].nickname = _nickname;
        userInfos[_msgSender()].city = _city;
        userInfos[_msgSender()].tags = _tags;

        emit UserInfoUpdated(_msgSender(), _nickname, _city, _tags);
    }

    function getUserInfo(address user) public view returns (string memory nickname, string memory city, string memory tags) {
        UserInfo storage info = userInfos[user];
        return (info.nickname, info.city, info.tags);
    }

    function getBalance(address user) public view returns (uint256) {
        return eochoToken.balanceOf(user);
    }

    function getAllowance(address owner, address spender) public view returns (uint256) {
        return eochoToken.allowance(owner, spender);
    }

    function setExchangeGiftContract(address _contract) public onlyOwner {
        exchangeGiftContract = _contract;
    }

    function setEochoHelpContract(address _contract) public onlyOwner {
        eochoHelpContract = _contract;
    }

    function setCoordinator(address _coordinator) public onlyOwner {
        coordinator = _coordinator;
    }
}

// =========================================================================
// 3. ExchangeGift - 圣诞节限定活动
// =========================================================================
contract ExchangeGift is Initializable, Ownable, ReentrancyGuard {
    enum TaskStatus {
        Pending, Requested, Approved, Delivery, Confirmed, Cancelled, Disputed, Completed
    }

    struct GiftTask {
        uint256 taskId;
        address payable initiator; 
        address payable partner;   
        uint256 collateral;        
        uint64 pendingExpiry;      
        string city;
        string wishlist;
        string offerlist;
        bytes32 shippingAddressHash; 
        TaskStatus status;
        uint64 deliveryConfirmExpiry; 
        bool initiatorDelivered;
        bool partnerDelivered;
        bool initiatorConfirmed;
        bool partnerConfirmed;
    }

    EverEchoCore public core;
    IEOCHOToken public eochoToken; 
    uint256 public nextTaskId = 1;
    mapping(uint256 => GiftTask) public giftTasks;
    uint256 public constant GIFT_COLLATERAL = 20 * 10**18; 
    uint256 public constant PENDING_TIMEOUT = 15 days;
    uint256 public constant DELIVERY_ENTRY_TIMEOUT = 3 days;
    uint256 public constant CONFIRM_RECEIPT_TIMEOUT = 7 days;

    event TaskCreated(uint256 indexed taskId, address indexed initiator, string city);
    event ExchangeRequested(uint256 indexed taskId, address indexed partner);
    event ExchangeApproved(uint256 indexed taskId, address indexed partner);
    event ExchangeRejected(uint256 indexed taskId);
    event TaskStatusChanged(uint256 indexed taskId, TaskStatus newStatus);
    event DeliveryEntered(uint256 indexed taskId, address indexed user, bytes32 trackingNumberHash);
    event ReceiptConfirmed(uint256 indexed taskId, address indexed user);
    event DisputeRaised(uint256 indexed taskId, address indexed disputer);
    event TaskCompleted(uint256 indexed taskId, address initiator, address partner);

    constructor() Ownable(msg.sender) {}

    function initialize(address _coreAddress, address _eochoToken) public initializer {
        _transferOwnership(_coreAddress); 
        core = EverEchoCore(_coreAddress);
        eochoToken = IEOCHOToken(_eochoToken); 
    }
    
    modifier onlyTaskParticipant(uint256 _taskId) {
        require(_msgSender() == giftTasks[_taskId].initiator || _msgSender() == giftTasks[_taskId].partner, "ExchangeGift: Not a participant");
        _;
    }

    // 修复: 使用 Storage 指针逐个赋值，解决 "Stack too deep" 问题
    function createExchangeTask(
        string memory _city,
        bytes32 _shippingAddressHash,
        string memory _wishlist,
        string memory _offerlist
    ) public nonReentrant {
        core.ensureRegistered(_msgSender());
        require(eochoToken.transferFrom(_msgSender(), address(this), GIFT_COLLATERAL), "EOCHO: Token transfer failed");

        uint256 id = nextTaskId;
        nextTaskId++;

        // 优化：直接操作 Storage，避免在栈上创建庞大的 Struct
        GiftTask storage newTask = giftTasks[id];
        newTask.taskId = id;
        newTask.initiator = payable(_msgSender());
        // partner 默认为 address(0)
        newTask.collateral = GIFT_COLLATERAL;
        newTask.pendingExpiry = uint64(block.timestamp + PENDING_TIMEOUT);
        newTask.city = _city;
        newTask.wishlist = _wishlist;
        newTask.offerlist = _offerlist;
        newTask.shippingAddressHash = _shippingAddressHash;
        newTask.status = TaskStatus.Pending;
        // 其他 bool 字段默认为 false
        // deliveryConfirmExpiry 默认为 0

        emit TaskCreated(id, _msgSender(), _city);
        emit TaskStatusChanged(id, TaskStatus.Pending);
    }

    function requestExchange(uint256 _taskId) public nonReentrant {
        core.ensureRegistered(_msgSender());

        GiftTask storage task = giftTasks[_taskId];
        require(task.status == TaskStatus.Pending, "ExchangeGift: Task is not Pending");
        require(_msgSender() != task.initiator, "ExchangeGift: Cannot request self");

        task.partner = payable(_msgSender());
        task.status = TaskStatus.Requested;
        emit ExchangeRequested(_taskId, _msgSender());
        emit TaskStatusChanged(_taskId, TaskStatus.Requested);
    }

    function approveExchange(uint256 _taskId) public nonReentrant {
        GiftTask storage task = giftTasks[_taskId];
        require(task.status == TaskStatus.Requested, "ExchangeGift: Task not in Requested state");
        require(_msgSender() == task.initiator, "ExchangeGift: Only initiator can approve");
        require(task.partner != address(0), "ExchangeGift: Partner not set");

        require(eochoToken.transferFrom(task.partner, address(this), GIFT_COLLATERAL), "EOCHO: Partner token transfer failed");
        task.collateral = task.collateral + GIFT_COLLATERAL;

        task.status = TaskStatus.Approved;
        task.deliveryConfirmExpiry = uint64(block.timestamp + DELIVERY_ENTRY_TIMEOUT);
        
        emit ExchangeApproved(_taskId, task.partner);
        emit TaskStatusChanged(_taskId, TaskStatus.Approved);
    }

    function rejectExchange(uint256 _taskId) public {
        GiftTask storage task = giftTasks[_taskId];
        require(task.status == TaskStatus.Requested, "ExchangeGift: Task not in Requested state");
        require(_msgSender() == task.initiator, "ExchangeGift: Only initiator can reject");

        task.partner = payable(address(0));
        task.status = TaskStatus.Pending;
        emit ExchangeRejected(_taskId);
        emit TaskStatusChanged(_taskId, TaskStatus.Pending);
    }

    function enterDelivery(uint256 _taskId, bytes32 _trackingNumberHash) public nonReentrant onlyTaskParticipant(_taskId) {
        GiftTask storage task = giftTasks[_taskId];
        require(task.status == TaskStatus.Approved || task.status == TaskStatus.Delivery, "ExchangeGift: Task not Approved or Delivery");
        
        require(block.timestamp <= task.deliveryConfirmExpiry, "ExchangeGift: Delivery entry window expired");

        if (_msgSender() == task.initiator) {
            task.initiatorDelivered = true;
        } else {
            task.partnerDelivered = true;
        }
        
        emit DeliveryEntered(_taskId, _msgSender(), _trackingNumberHash);

        if (task.initiatorDelivered && task.partnerDelivered) {
            task.status = TaskStatus.Delivery;
            task.deliveryConfirmExpiry = uint64(block.timestamp + CONFIRM_RECEIPT_TIMEOUT);
            emit TaskStatusChanged(_taskId, TaskStatus.Delivery);
        }
    }

    function confirmReceipt(uint256 _taskId) public nonReentrant onlyTaskParticipant(_taskId) {
        GiftTask storage task = giftTasks[_taskId];
        require(task.status == TaskStatus.Delivery, "ExchangeGift: Task not in Delivery state");
        
        if (_msgSender() == task.initiator) {
            task.initiatorConfirmed = true;
        } else {
            task.partnerConfirmed = true;
        }

        emit ReceiptConfirmed(_taskId, _msgSender());

        if (task.initiatorConfirmed && task.partnerConfirmed) {
            require(eochoToken.transfer(task.initiator, task.collateral / 2), "EOCHO: Initiator refund failed");
            require(eochoToken.transfer(task.partner, task.collateral / 2), "EOCHO: Partner refund failed");
            
            task.status = TaskStatus.Completed;
            emit TaskCompleted(_taskId, task.initiator, task.partner);
            emit TaskStatusChanged(_taskId, TaskStatus.Completed);
        }
    }

    function cancelTask(uint256 _taskId) public nonReentrant onlyTaskParticipant(_taskId) {
        GiftTask storage task = giftTasks[_taskId];
        require(task.status == TaskStatus.Pending || task.status == TaskStatus.Approved, "ExchangeGift: Cannot cancel after Delivery started");
        
        if (task.status == TaskStatus.Pending) {
             require(_msgSender() == task.initiator, "ExchangeGift: Only initiator can cancel pending task");
        } else { 
             require(!task.initiatorDelivered && !task.partnerDelivered, "ExchangeGift: Cannot cancel after Delivery entered");
        }
        
        if (task.initiator != address(0)) {
            require(eochoToken.transfer(task.initiator, GIFT_COLLATERAL), "EOCHO: Initiator refund failed");
        }
        if (task.partner != address(0) && task.status == TaskStatus.Approved) {
            require(eochoToken.transfer(task.partner, GIFT_COLLATERAL), "EOCHO: Partner refund failed");
        }
        
        task.status = TaskStatus.Cancelled;
        emit TaskStatusChanged(_taskId, TaskStatus.Cancelled);
    }
    
    function checkPendingExpiry(uint256 _taskId) public {
        GiftTask storage task = giftTasks[_taskId];
        require(task.status == TaskStatus.Pending, "ExchangeGift: Task not Pending");
        require(block.timestamp > task.pendingExpiry, "ExchangeGift: Task not expired yet");
        
        require(eochoToken.transfer(task.initiator, GIFT_COLLATERAL), "EOCHO: Initiator refund failed on expiry");
        
        task.status = TaskStatus.Cancelled;
        emit TaskStatusChanged(_taskId, TaskStatus.Cancelled);
    }

    function disputeTask(uint256 _taskId) public nonReentrant onlyTaskParticipant(_taskId) {
        GiftTask storage task = giftTasks[_taskId];
        require(task.status == TaskStatus.Approved || task.status == TaskStatus.Delivery, "ExchangeGift: Cannot dispute in current state");
        
        task.status = TaskStatus.Disputed;
        emit DisputeRaised(_taskId, _msgSender());
        emit TaskStatusChanged(_taskId, TaskStatus.Disputed);
    }

    function resolveDispute(uint256 _taskId, uint8 _winner) public nonReentrant {
        require(_msgSender() == EverEchoCore(owner()).coordinator(), "ExchangeGift: Only coordinator can resolve");
        GiftTask storage task = giftTasks[_taskId];
        require(task.status == TaskStatus.Disputed, "ExchangeGift: Task not in Disputed state");

        if (_winner == 0) {
            require(eochoToken.transfer(task.initiator, task.collateral / 2), "EOCHO: Initiator refund failed");
            require(eochoToken.transfer(owner(), task.collateral / 2), "EOCHO: Penalty transfer failed"); 
        } else if (_winner == 1) {
            require(eochoToken.transfer(task.partner, task.collateral / 2), "EOCHO: Partner refund failed");
            require(eochoToken.transfer(owner(), task.collateral / 2), "EOCHO: Penalty transfer failed");
        } else if (_winner == 2) {
            require(eochoToken.transfer(task.initiator, GIFT_COLLATERAL / 2), "EOCHO: Initiator partial refund failed");
            require(eochoToken.transfer(task.partner, GIFT_COLLATERAL / 2), "EOCHO: Partner partial refund failed");
            require(eochoToken.transfer(owner(), task.collateral - GIFT_COLLATERAL), "EOCHO: Penalty transfer failed");
        }
        
        task.status = TaskStatus.Completed;
        emit TaskCompleted(_taskId, task.initiator, task.partner);
        emit TaskStatusChanged(_taskId, TaskStatus.Completed);
    }
}

// =========================================================================
// 4. EochoHelp - 长期互助活动
// =========================================================================
contract EochoHelp is Initializable, Ownable, ReentrancyGuard {
    enum HelpType { CityHelp, Tech, Consulting, Other }
    enum TaskStatus { Open, Accepted, Completed, Cancelled }

    struct HelpTask {
        uint256 taskId;
        address payable requester; 
        address payable helper;    
        uint256 collateral;        
        HelpType taskType;
        string content;
        uint64 acceptedAt;         
        bytes32 contactInfoHash;   
        TaskStatus status;
    }

    EverEchoCore public core;
    IEOCHOToken public eochoToken; 
    uint256 public nextTaskId = 1;
    mapping(uint256 => HelpTask) public helpTasks;
    uint256 public constant MIN_COLLATERAL = 10 * 10**18;
    uint256 public constant COMPLETION_TIMEOUT = 7 days; 

    event HelpTaskCreated(uint256 indexed taskId, address indexed requester, HelpType taskType, uint256 collateral);
    event HelpTaskAccepted(uint256 indexed taskId, address indexed helper);
    event HelpTaskCompleted(uint256 indexed taskId, address indexed requester, address indexed helper, uint256 reward);
    event HelpTaskCancelled(uint256 indexed taskId);
    event HelpTaskStatusChanged(uint256 indexed taskId, TaskStatus newStatus);

    constructor() Ownable(msg.sender) {}

    function initialize(address _coreAddress, address _eochoToken) public initializer {
        _transferOwnership(_coreAddress);
        core = EverEchoCore(_coreAddress);
        eochoToken = IEOCHOToken(_eochoToken); 
    }

    // 修复: 使用 Storage 指针逐个赋值，解决 "Stack too deep" 问题
    function createHelpTask(
        HelpType _type,
        string memory _content,
        uint256 _collateral,
        bytes32 _contactInfoHash 
    ) public nonReentrant {
        core.ensureRegistered(_msgSender());

        require(_collateral >= MIN_COLLATERAL, "EochoHelp: Collateral must be at least 10 EOCHOs");
        require(eochoToken.transferFrom(_msgSender(), address(this), _collateral), "EOCHO: Token transfer failed");

        uint256 id = nextTaskId;
        nextTaskId++;

        // 优化：直接操作 Storage
        HelpTask storage newTask = helpTasks[id];
        newTask.taskId = id;
        newTask.requester = payable(_msgSender());
        // helper 默认为 address(0)
        newTask.collateral = _collateral;
        newTask.taskType = _type;
        newTask.content = _content;
        newTask.contactInfoHash = _contactInfoHash;
        newTask.status = TaskStatus.Open;
        // acceptedAt 默认为 0

        emit HelpTaskCreated(id, _msgSender(), _type, _collateral);
        emit HelpTaskStatusChanged(id, TaskStatus.Open);
    }

    function acceptHelpTask(uint256 _taskId) public nonReentrant {
        core.ensureRegistered(_msgSender());

        HelpTask storage task = helpTasks[_taskId];
        require(task.status == TaskStatus.Open, "EochoHelp: Task is not open");
        require(_msgSender() != task.requester, "EochoHelp: Cannot accept your own task");

        task.helper = payable(_msgSender());
        task.acceptedAt = uint64(block.timestamp);
        task.status = TaskStatus.Accepted;
        
        emit HelpTaskAccepted(_taskId, _msgSender());
        emit HelpTaskStatusChanged(_taskId, TaskStatus.Accepted);
    }

    function cancelHelpTask(uint256 _taskId) public nonReentrant {
        HelpTask storage task = helpTasks[_taskId];
        require(_msgSender() == task.requester, "EochoHelp: Only requester can cancel");
        require(task.status == TaskStatus.Open, "EochoHelp: Cannot cancel after task is accepted");
        
        require(eochoToken.transfer(task.requester, task.collateral), "EOCHO: Refund failed");
        
        task.status = TaskStatus.Cancelled;
        emit HelpTaskCancelled(_taskId);
        emit HelpTaskStatusChanged(_taskId, TaskStatus.Cancelled);
    }

    function confirmHelpCompletion(uint256 _taskId) public nonReentrant {
        HelpTask storage task = helpTasks[_taskId];
        require(_msgSender() == task.requester, "EochoHelp: Only requester can confirm");
        require(task.status == TaskStatus.Accepted, "EochoHelp: Task not in Accepted state");

        require(eochoToken.transfer(task.helper, task.collateral), "EOCHO: Payment failed");

        task.status = TaskStatus.Completed;
        emit HelpTaskCompleted(_taskId, task.requester, task.helper, task.collateral);
        emit HelpTaskStatusChanged(_taskId, TaskStatus.Completed);
    }

    function checkAutoCompletion(uint256 _taskId) public nonReentrant {
        HelpTask storage task = helpTasks[_taskId];
        require(task.status == TaskStatus.Accepted, "EochoHelp: Task not in Accepted state");
        require(block.timestamp >= task.acceptedAt + COMPLETION_TIMEOUT, "EochoHelp: Timeout not reached");
        
        require(eochoToken.transfer(task.helper, task.collateral), "EOCHO: Auto payment failed");

        task.status = TaskStatus.Completed;
        emit HelpTaskCompleted(_taskId, task.requester, task.helper, task.collateral);
        emit HelpTaskStatusChanged(_taskId, TaskStatus.Completed);
    }
}