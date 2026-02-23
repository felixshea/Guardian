// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IGuardian - Core interface for the Portfolio Guardian system
/// @notice All modules implement this base interface for unified access control
interface IGuardian {
    // ─── Errors ───────────────────────────────────────────────────────────────
    error Unauthorized();
    error InvalidParameter();
    error RiskLimitExceeded();
    error ModulePaused();
    error InsufficientFee();
    error UserNotRegistered();

    // ─── Structs ──────────────────────────────────────────────────────────────
    struct User {
        bool registered;
        bool active;
        address delegate;       // optional EOA/agent allowed to act on behalf
        uint96 feesAccrued;     // fees owed to protocol (in GUARDIAN token)
        uint256 registeredAt;
    }

    // ─── Events ───────────────────────────────────────────────────────────────
    event UserRegistered(address indexed user, address indexed delegate);
    event UserDeactivated(address indexed user);
    event FeeCollected(address indexed user, uint256 amount);
    event ModuleEnabled(address indexed module);
    event ModuleDisabled(address indexed module);

    // ─── Functions ────────────────────────────────────────────────────────────
    function registerUser(address delegate) external;
    function deactivateUser() external;
    function getUserInfo(address user) external view returns (User memory);
    function isActiveUser(address user) external view returns (bool);
}

/// @title IPriceModule
interface IPriceModule {
    struct PriceAlert {
        uint256 targetPrice;    // 8 decimals (Chainlink standard)
        bool alertAbove;        // true = alert when price >= target
        bool executeAction;     // true = trigger trading action on alert
        bool active;
        uint256 lastTriggered;
        uint256 cooldownPeriod; // seconds between re-triggers
    }

    event PriceAlertSet(address indexed user, uint256 targetPrice, bool alertAbove);
    event PriceAlertTriggered(address indexed user, uint256 currentPrice, uint256 targetPrice);
    event PriceAlertCleared(address indexed user);

    function setPriceAlert(uint256 targetPrice, bool alertAbove, bool executeAction, uint256 cooldown) external;
    function clearPriceAlert() external;
    function getLatestPrice() external view returns (int256 price, uint256 updatedAt);
    function getUserAlert(address user) external view returns (PriceAlert memory);
}

/// @title IWalletModule
interface IWalletModule {
    struct WalletConfig {
        uint256 incomingThreshold; // wei — alert if transfer exceeds this
        uint256 lastReportTime;
        uint256 reportInterval;    // default 7 days
        bool active;
    }

    event LargeTransferDetected(address indexed wallet, address indexed from, uint256 amount);
    event WeeklyReportEmitted(address indexed wallet, uint256 ethBalance, uint256 timestamp);
    event WalletConfigUpdated(address indexed user, uint256 threshold);

    function configureWallet(uint256 incomingThreshold, uint256 reportInterval) external;
    function getWalletConfig(address user) external view returns (WalletConfig memory);
    function checkAndEmitReport(address user) external;
}

/// @title ITradingModule
interface ITradingModule {
    struct TradeConfig {
        uint256 buyBelowPrice;      // buy ETH if price drops below (8 dec)
        uint256 sellAbovePrice;     // sell ETH if price rises above (8 dec)
        uint256 buyAmountUSDC;      // USDC amount to spend on buy (6 dec)
        uint256 sellAmountETH;      // ETH amount to sell on take-profit (18 dec)
        uint24  poolFee;            // Uniswap V3 pool fee tier (500 / 3000 / 10000)
        uint256 slippageBps;        // e.g. 50 = 0.5%
        bool    active;
    }

    event TradeBuyExecuted(address indexed user, uint256 usdcSpent, uint256 ethReceived);
    event TradeSellExecuted(address indexed user, uint256 ethSold, uint256 usdcReceived);
    event TradeConfigUpdated(address indexed user);
    event TradeSkipped(address indexed user, string reason);

    function setTradeConfig(TradeConfig calldata config) external;
    function getTradeConfig(address user) external view returns (TradeConfig memory);
    function executeBuy(address user) external returns (uint256 ethReceived);
    function executeSell(address user) external returns (uint256 usdcReceived);
}

/// @title IRiskModule
interface IRiskModule {
    struct RiskParams {
        uint256 stopLossPrice;      // absolute ETH price (8 dec) → liquidate if below
        uint256 dailyMaxLossUSD;    // max USD loss per day (8 dec)
        uint256 dailyLossAccrued;   // rolling daily loss tracker
        uint256 lastResetTime;
        bool    automationDisabled; // kill switch
    }

    event StopLossTriggered(address indexed user, uint256 price);
    event DailyLossLimitReached(address indexed user, uint256 totalLoss);
    event RiskParamsUpdated(address indexed user);
    event AutomationResumed(address indexed user);

    function setRiskParams(uint256 stopLossPrice, uint256 dailyMaxLossUSD) external;
    function getRiskParams(address user) external view returns (RiskParams memory);
    function recordLoss(address user, uint256 lossUSD) external;
    function isAutomationAllowed(address user) external view returns (bool);
    function resetDailyLoss(address user) external;
    function disableAutomation(address user) external;
    function resumeAutomation() external;
}
