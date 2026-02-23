// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IWalletModule} from "../interfaces/IGuardian.sol";

/// @title WalletModule
/// @notice Tracks per-user wallet monitoring configuration and emits
///         on-chain events for large incoming transfers and scheduled reports.
///
/// @dev    This module is event-based — it does NOT hold funds or move tokens.
///         Off-chain indexers (The Graph, custom bots) listen to emitted events
///         to power the "portfolio dashboard" and notification system.
///
///         Large transfer detection is done via a hook pattern: the monitored
///         wallet (or a relayer) calls `reportTransfer()` after receiving funds.
///         For trustless detection, integrate with an on-chain transfer hook or
///         use Chainlink Automation with a custom event log trigger.
contract WalletModule is IWalletModule, Ownable2Step {

    // ─── Constants ────────────────────────────────────────────────────────────
    uint256 public constant MIN_REPORT_INTERVAL = 1 days;
    uint256 public constant DEFAULT_REPORT_INTERVAL = 7 days;

    // ─── Immutables ───────────────────────────────────────────────────────────
    address public immutable guardianCore;

    // ─── Storage ──────────────────────────────────────────────────────────────
    mapping(address => WalletConfig) private _configs;

    // ─── Constructor ──────────────────────────────────────────────────────────
    constructor(address _guardianCore, address _owner) Ownable(_owner) {
        require(_guardianCore != address(0), "invalid core");
        guardianCore = _guardianCore;
    }

    // ─── User Functions ───────────────────────────────────────────────────────

    /// @notice Configure wallet monitoring for the caller.
    /// @param incomingThreshold Minimum ETH (in wei) that triggers a large-transfer alert.
    ///                          Set to 0 to disable transfer alerts.
    /// @param reportInterval    How often (seconds) a balance report should be emitted.
    ///                          Minimum 1 day; pass 0 to use default 7 days.
    function configureWallet(uint256 incomingThreshold, uint256 reportInterval) external override {
        uint256 interval = reportInterval == 0 ? DEFAULT_REPORT_INTERVAL : reportInterval;
        require(interval >= MIN_REPORT_INTERVAL, "interval too short");

        _configs[msg.sender] = WalletConfig({
            incomingThreshold: incomingThreshold,
            lastReportTime:    block.timestamp,
            reportInterval:    interval,
            active:            true
        });

        emit WalletConfigUpdated(msg.sender, incomingThreshold);
    }

    /// @notice Disable wallet monitoring
    function disableMonitoring() external {
        _configs[msg.sender].active = false;
    }

    /// @notice Report an incoming ETH transfer for monitoring.
    ///         Called by the monitored wallet itself or a trusted relayer.
    ///         For automatic detection without user action, use a Chainlink log trigger
    ///         subscribed to Transfer events on the WETH contract.
    /// @param from    Sender of the transfer
    /// @param amount  ETH amount received (in wei)
    function reportTransfer(address from, uint256 amount) external {
        WalletConfig memory config = _configs[msg.sender];
        if (!config.active) return;
        if (config.incomingThreshold == 0) return;
        if (amount >= config.incomingThreshold) {
            emit LargeTransferDetected(msg.sender, from, amount);
        }
    }

    // ─── Automation Hook ──────────────────────────────────────────────────────

    /// @notice Called by GuardianCore.performUpkeep to emit a scheduled balance report.
    ///         The actual balance is read from the blockchain and passed in by the keeper.
    /// @param user       Address of the monitored wallet
    function checkAndEmitReport(address user) external override {
        require(msg.sender == guardianCore, "only core");

        WalletConfig storage config = _configs[user];
        if (!config.active) return;
        if (block.timestamp < config.lastReportTime + config.reportInterval) return;

        config.lastReportTime = block.timestamp;

        // Emit ETH balance; off-chain indexers aggregate token balances via multicall
        emit WeeklyReportEmitted(user, user.balance, block.timestamp);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    function getWalletConfig(address user) external view override returns (WalletConfig memory) {
        return _configs[user];
    }

    /// @notice True if a report is due for the user
    function isReportDue(address user) external view returns (bool) {
        WalletConfig memory config = _configs[user];
        return config.active && block.timestamp >= config.lastReportTime + config.reportInterval;
    }
}
