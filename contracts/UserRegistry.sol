// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./EOCHO.sol";

contract UserRegistry is AccessControl, ReentrancyGuard {
    using SafeERC20 for EOCHO;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    EOCHO public immutable token;
    uint256 public AIRDROP_AMOUNT = 100 ether;

    struct User {
        address wallet;
        string nickname;
        string city;
        string[] tags;
        uint256 createdAt;
        bool whiteListed;
        bool airdropped;
    }

    mapping(address => User) private users;

    event UserRegistered(address indexed user, string nickname, string city);
    event EOCHOAirdrop(address indexed to, uint256 amount);

    constructor(EOCHO _token) {
        token = _token;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    function registerIfNeeded(
        string calldata nickname,
        string calldata city,
        string[] calldata tags
    ) external nonReentrant {
        User storage u = users[msg.sender];

        if (u.createdAt == 0) {
            u.wallet = msg.sender;
            u.nickname = nickname;
            u.city = city;

            for (uint i = 0; i < tags.length; i++) {
                u.tags.push(tags[i]);
            }

            u.createdAt = block.timestamp;
            u.whiteListed = true;

            emit UserRegistered(msg.sender, nickname, city);

            // airdrop
            if (!u.airdropped) {
                u.airdropped = true;
                token.mint(msg.sender, AIRDROP_AMOUNT);
                emit EOCHOAirdrop(msg.sender, AIRDROP_AMOUNT);
            }
        }
    }

    function getUser(address who) external view returns (User memory) {
        return users[who];
    }

    function setAirdropAmount(uint256 amount) external onlyRole(ADMIN_ROLE) {
        AIRDROP_AMOUNT = amount;
    }
}
