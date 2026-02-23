// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IGuardian} from "../interfaces/IGuardian.sol";
import {IPriceModule} from "../interfaces/IGuardian.sol";
import {IWalletModule} from "../interfaces/IGuardian.sol";
import {ITradingModule} from "../interfaces/IGuardian.sol";
import {IRiskModule} from "../interfaces/IGuardian.sol";

// Chainlink Automation interface
import {AutomationCompatibleInterface} from
    "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";

/// @title GuardianCore
/// @notice Central registry and orchestration hub for the Portfolio Guardian system.
///         Handles user registration, module routing, fee accounting, and
///         Chainlink Automation callbacks.
/// @dev    Non-custodial — this contract never holds user funds. It only holds
///         approved permissions and routes calls to DeFi protocols on behalf of users.
contract GuardianCore is
    IGuardian,
    AutomationCompatibleInterface,
    Ownable2Step,
    Pausable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    // ─── Constants ────────────────────────────────────────────────────────────
    uint256 public constant FEE_PER_TRIGGER = 0.001 ether;          // ETH fee per automation trigger
    uint256 public constant PROTOCOL_FEE_TOKEN = 1e18;              // 1 GUARDIAN token per trigger
    uint256 public constant MAX_USERS_PER_UPKEEP = 10;              // gas bound per upkeep call
    uint256 public constant AUTOMATION_REGISTRY_VERSION = 2;        // Chainlink Automation v2

    // ─── Immutables ───────────────────────────────────────────────────────────
    address public immutable priceModule;
    address public immutable walletModule;
    address public immutable tradingModule;
    address public immutable riskModule;
    IERC20  public immutable guardianToken;   // optional protocol fee token

    // ─── Storage ──────────────────────────────────────────────────────────────
    mapping(address => User) private _users;
    address[] private _userList;                      // enumerable for automation scanning
    mapping(address => uint256) private _userIndex;   // user → index in _userList (1-based)

    /// @notice Trusted forwarder addresses (Chainlink Automation, Bankr agent, etc.)
    mapping(address => bool) public trustedForwarders;

    /// @notice Collected protocol fees per user (guardian token)
    mapping(address => uint256) public pendingFees;

    uint256 public totalFeesCollected;

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyRegistered() {
        if (!_users[msg.sender].registered) revert UserNotRegistered();
        _;
    }

    modifier onlyActiveUser(address user) {
        if (!_users[user].active) revert UserNotRegistered();
        _;
    }

    modifier onlyTrustedOrOwner() {
        if (!trustedForwarders[msg.sender] && msg.sender != owner()) revert Unauthorized();
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(
        address _priceModule,
        address _walletModule,
        address _tradingModule,
        address _riskModule,
        address _guardianToken,
        address _initialOwner
    ) Ownable(_initialOwner) {
        require(_priceModule != address(0), "invalid priceModule");
        require(_walletModule != address(0), "invalid walletModule");
        require(_tradingModule != address(0), "invalid tradingModule");
        require(_riskModule != address(0), "invalid riskModule");

        priceModule  = _priceModule;
        walletModule = _walletModule;
        tradingModule = _tradingModule;
        riskModule   = _riskModule;
        guardianToken = IERC20(_guardianToken); // can be address(0) to disable token fees
    }

    // ─── User Registration ────────────────────────────────────────────────────

    /// @notice Register a user account with an optional delegate address.
    ///         Delegate can be a hot wallet, AI agent wallet (Bankr), or EOA.
    /// @param delegate Address authorized to trigger automations on behalf of user.
    ///                 Pass address(0) to use only own wallet.
    function registerUser(address delegate) external override whenNotPaused {
        if (_users[msg.sender].registered) revert InvalidParameter();

        _users[msg.sender] = User({
            registered:   true,
            active:       true,
            delegate:     delegate,
            feesAccrued:  0,
            registeredAt: block.timestamp
        });

        // Store in enumerable list for automation scanning
        _userList.push(msg.sender);
        _userIndex[msg.sender] = _userList.length; // 1-based

        emit UserRegistered(msg.sender, delegate);
    }

    /// @notice Deactivate account. Stops all automations immediately.
    function deactivateUser() external override onlyRegistered {
        _users[msg.sender].active = false;
        emit UserDeactivated(msg.sender);
    }

    /// @notice Update delegate address
    function updateDelegate(address newDelegate) external onlyRegistered {
        _users[msg.sender].delegate = newDelegate;
        emit UserRegistered(msg.sender, newDelegate);
    }

    // ─── Chainlink Automation ─────────────────────────────────────────────────

    /// @notice Called off-chain by Chainlink nodes every block to determine
    ///         if performUpkeep should be executed.
    /// @dev    Scans up to MAX_USERS_PER_UPKEEP active users for any triggered conditions.
    ///         Returns encoded list of users + action types that need execution.
    function checkUpkeep(bytes calldata checkData)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        // Decode pagination offset from checkData (allows multiple Automation jobs
        // covering different user index ranges)
        uint256 startIndex = checkData.length > 0 ? abi.decode(checkData, (uint256)) : 0;

        address[] memory toProcess = new address[](MAX_USERS_PER_UPKEEP);
        uint8[]   memory actions   = new uint8[](MAX_USERS_PER_UPKEEP);   // bitmask per user
        uint256   count = 0;
        uint256   len   = _userList.length;

        for (uint256 i = startIndex; i < len && count < MAX_USERS_PER_UPKEEP; i++) {
            address user = _userList[i];
            if (!_users[user].active) continue;
            if (!IRiskModule(riskModule).isAutomationAllowed(user)) continue;

            uint8 actionBits = _evaluateUser(user);
            if (actionBits > 0) {
                toProcess[count] = user;
                actions[count]   = actionBits;
                count++;
            }
        }

        if (count > 0) {
            upkeepNeeded = true;
            // Trim arrays to actual count
            assembly {
                mstore(toProcess, count)
                mstore(actions, count)
            }
            performData = abi.encode(toProcess, actions);
        }
    }

    /// @notice Executes actions for users flagged in checkUpkeep.
    ///         Called by Chainlink Automation nodes on-chain.
    function performUpkeep(bytes calldata performData) external override nonReentrant whenNotPaused {
        (address[] memory users, uint8[] memory actions) =
            abi.decode(performData, (address[], uint8[]));

        require(users.length == actions.length, "length mismatch");
        require(users.length <= MAX_USERS_PER_UPKEEP, "too many users");

        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            if (!_users[user].active) continue;
            if (!IRiskModule(riskModule).isAutomationAllowed(user)) continue;

            _executeActions(user, actions[i]);
            _collectFee(user);
        }
    }

    // ─── Internal Automation Logic ────────────────────────────────────────────

    /// Action bitmask constants
    uint8 internal constant ACTION_PRICE_BUY   = 0x01;
    uint8 internal constant ACTION_PRICE_SELL  = 0x02;
    uint8 internal constant ACTION_WALLET_RPT  = 0x04;
    uint8 internal constant ACTION_STOP_LOSS   = 0x08;

    /// @dev Read-only evaluation of what actions a user currently needs
    function _evaluateUser(address user) internal view returns (uint8 bits) {
        (int256 currentPrice,) = IPriceModule(priceModule).getLatestPrice();
        uint256 price = uint256(currentPrice);

        // ── Price alert check ──────────────────────────────────────────────
        IPriceModule.PriceAlert memory alert = IPriceModule(priceModule).getUserAlert(user);
        if (alert.active && block.timestamp >= alert.lastTriggered + alert.cooldownPeriod) {
            bool triggered = alert.alertAbove
                ? price >= alert.targetPrice
                : price <= alert.targetPrice;
            if (triggered && alert.executeAction) {
                bits |= alert.alertAbove ? ACTION_PRICE_SELL : ACTION_PRICE_BUY;
            }
        }

        // ── Trading automation check ───────────────────────────────────────
        ITradingModule.TradeConfig memory tc = ITradingModule(tradingModule).getTradeConfig(user);
        if (tc.active) {
            if (tc.buyBelowPrice > 0 && price <= tc.buyBelowPrice)  bits |= ACTION_PRICE_BUY;
            if (tc.sellAbovePrice > 0 && price >= tc.sellAbovePrice) bits |= ACTION_PRICE_SELL;
        }

        // ── Stop loss check ────────────────────────────────────────────────
        IRiskModule.RiskParams memory rp = IRiskModule(riskModule).getRiskParams(user);
        if (rp.stopLossPrice > 0 && price <= rp.stopLossPrice) bits |= ACTION_STOP_LOSS;

        // ── Weekly wallet report ───────────────────────────────────────────
        IWalletModule.WalletConfig memory wc = IWalletModule(walletModule).getWalletConfig(user);
        if (wc.active && block.timestamp >= wc.lastReportTime + wc.reportInterval) {
            bits |= ACTION_WALLET_RPT;
        }
    }

    /// @dev Execute flagged actions for a user
    function _executeActions(address user, uint8 bits) internal {
        if (bits & ACTION_STOP_LOSS != 0) {
            // Stop loss takes priority — disables further automation
            IRiskModule(riskModule).disableAutomation(user);
            // Attempt emergency sell
            try ITradingModule(tradingModule).executeSell(user) returns (uint256) {} catch {}
            return; // skip other actions after stop loss
        }

        if (bits & ACTION_PRICE_BUY != 0) {
            try ITradingModule(tradingModule).executeBuy(user) returns (uint256) {} catch {}
        }

        if (bits & ACTION_PRICE_SELL != 0) {
            try ITradingModule(tradingModule).executeSell(user) returns (uint256) {} catch {}
        }

        if (bits & ACTION_WALLET_RPT != 0) {
            try IWalletModule(walletModule).checkAndEmitReport(user) {} catch {}
        }
    }

    /// @dev Collect protocol fee from user (pull pattern)
    function _collectFee(address user) internal {
        if (address(guardianToken) == address(0)) return;

        pendingFees[user] += PROTOCOL_FEE_TOKEN;
        totalFeesCollected += PROTOCOL_FEE_TOKEN;
        emit FeeCollected(user, PROTOCOL_FEE_TOKEN);
    }

    /// @notice User pays accrued fees in GUARDIAN token
    function payFees() external onlyRegistered {
        uint256 amount = pendingFees[msg.sender];
        if (amount == 0) revert InsufficientFee();
        pendingFees[msg.sender] = 0;
        guardianToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function setTrustedForwarder(address forwarder, bool trusted) external onlyOwner {
        trustedForwarders[forwarder] = trusted;
        emit ModuleEnabled(forwarder);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function withdrawFees(address recipient) external onlyOwner {
        uint256 bal = guardianToken.balanceOf(address(this));
        guardianToken.safeTransfer(recipient, bal);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    function getUserInfo(address user) external view override returns (User memory) {
        return _users[user];
    }

    function isActiveUser(address user) external view override returns (bool) {
        return _users[user].active;
    }

    function totalUsers() external view returns (uint256) {
        return _userList.length;
    }

    /// @notice Check if caller is user or their approved delegate
    function isAuthorizedCaller(address user, address caller) public view returns (bool) {
        return caller == user || caller == _users[user].delegate || trustedForwarders[caller];
    }
}
