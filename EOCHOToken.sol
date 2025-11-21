// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// 使用具名导入 (Named Imports) 以避免命名冲突和歧义
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
// Context 不需要显式导入给 EOCHOToken 使用，因为它是 ERC20/AccessControl 的基类
// 但 EverEchoCore 可能需要 Ownable (它也包含 Context)

// =========================================================================
// 1. EOCHOToken - ERC20代币合约
// =========================================================================
// 修复冲突：
// 1. 移除显式 Context 继承（它是隐式的）。
// 2. 使用 is ERC20, AccessControl 顺序。
contract EOCHOToken is ERC20, AccessControl {
    // 定义专用的 Minter 角色
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    // 初始空投数量 (100 EOCHOs)
    uint256 public constant INITIAL_AIRDROP_AMOUNT = 100 ether; 

    // 构造函数
    constructor(address initialAdmin) 
        ERC20("EverEcho Coin", "EOCHO") 
    {
        // 确保合约初始部署者拥有 DEFAULT_ADMIN_ROLE
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
    }

    // 授权核心合约铸造代币
    function grantMinterRole(address minter) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(MINTER_ROLE, minter);
    }

    // 内部铸造函数
    function mint(address to, uint256 amount) public {
        require(hasRole(MINTER_ROLE, _msgSender()), "EOCHO: Must have minter role");
        _mint(to, amount);
    }
}