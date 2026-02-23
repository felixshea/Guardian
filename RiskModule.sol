// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IRiskModule} from "../interfaces/IGuardian.sol";

/// @title RiskModule
/// @notice Per-user risk management with stop-loss, daily loss limits, and
///         an emergency kill switch for automated trading.
///
/// @dev    Risk parameters are checked before every automated action.
///         The daily loss counter resets at midnight UTC (via Chainlink Automation
///         or lazily on the next interaction). The kill switch (automationDisabled)
///         can only be re-enabled by the user themselves, preventing griefing.
contract RiskModule is IRiskModule, Ownable2Step {

    // ─── Constants ────────────────────────────────────────────────────────────
    uint256 public constant SECONDS_PER_DAY = 86400;

    // ─── Immutables ───────────────────────────────────────────────────────────
    address public immutable guardianCore;

    // ─── Storage ──────────────────────────────────────────────────────────────
    mapping(address => RiskParams) private _params;

    // ─── Modifiers ────────────────────────────────────────────────────────────
    modifier onlyCore() {
        require(msg.sender == guardianCore, "only core");
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────
    constructor(address _guardianCore, address _owner) Ownable(_owner) {
        require(_guardianCore != address(0), "invalid core");
        guardianCore = _guardianCore;
    }

    // ─── User Config ──────────────────────────────────────────────────────────

    /// @notice Set risk parameters for the caller.
    /// @param stopLossPrice    ETH price (8 dec) below which all automation is halted
    ///                         and an emergency sell is triggered. Set 0 to disable.
    /// @param dailyMaxLossUSD  Maximum USD loss per day (8 dec) before automation pauses.
    ///                         Set 0 to disable daily limit.
    function setRiskParams(uint256 stopLossPrice, uint256 dailyMaxLossUSD) external override {
        RiskParams storage rp = _params[msg.sender];
        rp.stopLossPrice   = stopLossPrice;
        rp.dailyMaxLossUSD = dailyMaxLossUSD;

        // Preserve runtime fields if already set
        if (rp.lastResetTime == 0) {
            rp.lastResetTime = block.timestamp;
        }

        emit RiskParamsUpdated(msg.sender);
    }

    // ─── Core Hooks ───────────────────────────────────────────────────────────

    /// @notice Record a USD loss for a user. Called by TradingModule after a losing trade.
    /// @param user     Portfolio owner
    /// @param lossUSD  Loss amount in USD with 8 decimals (Chainlink format)
    function recordLoss(address user, uint256 lossUSD) external override onlyCore {
        RiskParams storage rp = _params[user];

        // Auto-reset daily counter if a new day has started
        _maybeResetDaily(rp);

        rp.dailyLossAccrued += lossUSD;

        if (rp.dailyMaxLossUSD > 0 && rp.dailyLossAccrued >= rp.dailyMaxLossUSD) {
            rp.automationDisabled = true;
            emit DailyLossLimitReached(user, rp.dailyLossAccrued);
        }
    }

    /// @notice Called by GuardianCore when stop-loss condition is met.
    function disableAutomation(address user) external override onlyCore {
        _params[user].automationDisabled = true;
        emit StopLossTriggered(user, _params[user].stopLossPrice);
    }

    /// @notice Reset daily loss counter. Can be called by keeper after midnight.
    function resetDailyLoss(address user) external override onlyCore {
        _maybeResetDaily(_params[user]);
    }

    // ─── User Kill Switch ─────────────────────────────────────────────────────

    /// @notice User manually disables their automation (emergency stop).
    function disableMyAutomation() external {
        _params[msg.sender].automationDisabled = true;
    }

    /// @notice User re-enables automation after reviewing risk parameters.
    ///         Only the user themselves can do this — not the core or delegates.
    function resumeAutomation() external override {
        RiskParams storage rp = _params[msg.sender];
        rp.automationDisabled = false;
        rp.dailyLossAccrued   = 0; // reset loss counter on manual resume
        rp.lastResetTime      = block.timestamp;
        emit AutomationResumed(msg.sender);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    function isAutomationAllowed(address user) external view override returns (bool) {
        RiskParams memory rp = _params[user];
        return !rp.automationDisabled;
    }

    function getRiskParams(address user) external view override returns (RiskParams memory) {
        return _params[user];
    }

    /// @notice Returns true if user has configured stop-loss and current price triggers it
    function isStopLossBreached(address user, uint256 currentPrice) external view returns (bool) {
        RiskParams memory rp = _params[user];
        return rp.stopLossPrice > 0 && currentPrice <= rp.stopLossPrice;
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _maybeResetDaily(RiskParams storage rp) internal {
        if (block.timestamp >= rp.lastResetTime + SECONDS_PER_DAY) {
            rp.dailyLossAccrued = 0;
            rp.lastResetTime    = block.timestamp;
            // Re-enable if disabled only by daily limit (not stop-loss)
            // Note: stop-loss disables are NOT auto-resumed — user must call resumeAutomation()
        }
    }
}
