// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IPriceModule} from "../interfaces/IGuardian.sol";

/// @title PriceModule
/// @notice Manages per-user price alerts using Chainlink ETH/USD price feeds.
///         Supports both threshold-based alerts (above/below) with configurable
///         cooldown periods to prevent spam triggers.
///
/// @dev    Price data uses Chainlink's 8-decimal format throughout.
///         All comparisons are done in uint256 after sanity-checking feed freshness.
contract PriceModule is IPriceModule, Ownable2Step {

    // ─── Constants ────────────────────────────────────────────────────────────
    uint256 public constant PRICE_STALENESS_THRESHOLD = 3600; // 1 hour max age
    uint256 public constant MIN_COOLDOWN = 300;               // 5 min minimum cooldown

    // ─── Immutables ───────────────────────────────────────────────────────────
    AggregatorV3Interface public immutable ethUsdFeed;
    address public immutable guardianCore;

    // ─── Storage ──────────────────────────────────────────────────────────────
    mapping(address => PriceAlert) private _alerts;

    // ─── Modifiers ────────────────────────────────────────────────────────────
    modifier onlyCoreOrUser(address user) {
        require(msg.sender == guardianCore || msg.sender == user, "unauthorized");
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────
    constructor(address _ethUsdFeed, address _guardianCore, address _owner)
        Ownable(_owner)
    {
        require(_ethUsdFeed != address(0), "invalid feed");
        require(_guardianCore != address(0), "invalid core");
        ethUsdFeed   = AggregatorV3Interface(_ethUsdFeed);
        guardianCore = _guardianCore;
    }

    // ─── User Functions ───────────────────────────────────────────────────────

    /// @notice Set a price alert for the caller.
    /// @param targetPrice   Price threshold in USD with 8 decimals (e.g. 2000_00000000 = $2000)
    /// @param alertAbove    true → alert when price >= target; false → alert when price <= target
    /// @param executeAction true → execute associated trade on trigger
    /// @param cooldown      Minimum seconds between re-triggers (min 300s)
    function setPriceAlert(
        uint256 targetPrice,
        bool    alertAbove,
        bool    executeAction,
        uint256 cooldown
    ) external override {
        require(targetPrice > 0, "invalid price");
        require(cooldown >= MIN_COOLDOWN, "cooldown too short");

        _alerts[msg.sender] = PriceAlert({
            targetPrice:   targetPrice,
            alertAbove:    alertAbove,
            executeAction: executeAction,
            active:        true,
            lastTriggered: 0,
            cooldownPeriod: cooldown
        });

        emit PriceAlertSet(msg.sender, targetPrice, alertAbove);
    }

    /// @notice Deactivate and remove the caller's price alert
    function clearPriceAlert() external override {
        delete _alerts[msg.sender];
        emit PriceAlertCleared(msg.sender);
    }

    /// @notice Called by GuardianCore.performUpkeep to record that an alert fired
    /// @dev    Only core can call this to prevent users from manipulating lastTriggered
    function markAlertTriggered(address user) external {
        require(msg.sender == guardianCore, "only core");
        PriceAlert storage alert = _alerts[user];
        (int256 price,) = getLatestPrice();
        alert.lastTriggered = block.timestamp;

        emit PriceAlertTriggered(user, uint256(price), alert.targetPrice);
    }

    // ─── Price Feed ───────────────────────────────────────────────────────────

    /// @notice Fetch latest ETH/USD price from Chainlink, with staleness guard
    /// @return price      Latest price with 8 decimals
    /// @return updatedAt  Timestamp of last update
    function getLatestPrice() public view override returns (int256 price, uint256 updatedAt) {
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updated,
            uint80 answeredInRound
        ) = ethUsdFeed.latestRoundData();

        // Staleness check
        require(updated > 0, "round not complete");
        require(block.timestamp - updated <= PRICE_STALENESS_THRESHOLD, "price data stale");
        require(answeredInRound >= roundId, "stale round");
        require(answer > 0, "negative price");

        return (answer, updated);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    function getUserAlert(address user) external view override returns (PriceAlert memory) {
        return _alerts[user];
    }

    /// @notice Check if a user's alert is currently triggered (view only, no state change)
    function isAlertTriggered(address user) external view returns (bool triggered, uint256 currentPrice) {
        PriceAlert memory alert = _alerts[user];
        if (!alert.active) return (false, 0);
        if (block.timestamp < alert.lastTriggered + alert.cooldownPeriod) return (false, 0);

        (int256 price,) = getLatestPrice();
        currentPrice = uint256(price);

        triggered = alert.alertAbove
            ? currentPrice >= alert.targetPrice
            : currentPrice <= alert.targetPrice;
    }
}
