/**
 * Guardian Frontend Integration
 * Framework: Next.js + wagmi v2 + viem
 * 
 * Install:
 *   npm install wagmi viem @tanstack/react-query
 */

import { useReadContract, useWriteContract, useWatchContractEvent } from "wagmi";
import { parseUnits, formatUnits, parseAbi } from "viem";

// ─── Contract Addresses (Base Mainnet) ────────────────────────────────────────
export const ADDRESSES = {
  guardianCore:  process.env.NEXT_PUBLIC_GUARDIAN_CORE,
  priceModule:   process.env.NEXT_PUBLIC_PRICE_MODULE,
  walletModule:  process.env.NEXT_PUBLIC_WALLET_MODULE,
  tradingModule: process.env.NEXT_PUBLIC_TRADING_MODULE,
  riskModule:    process.env.NEXT_PUBLIC_RISK_MODULE,
};

// ─── ABIs ─────────────────────────────────────────────────────────────────────
const GUARDIAN_CORE_ABI = parseAbi([
  "function registerUser(address delegate) external",
  "function deactivateUser() external",
  "function updateDelegate(address newDelegate) external",
  "function getUserInfo(address user) external view returns (bool registered, bool active, address delegate, uint96 feesAccrued, uint256 registeredAt)",
  "function isActiveUser(address user) external view returns (bool)",
  "function pendingFees(address) external view returns (uint256)",
  "function payFees() external",
  "event UserRegistered(address indexed user, address indexed delegate)",
]);

const PRICE_MODULE_ABI = parseAbi([
  "function setPriceAlert(uint256 targetPrice, bool alertAbove, bool executeAction, uint256 cooldown) external",
  "function clearPriceAlert() external",
  "function getLatestPrice() external view returns (int256 price, uint256 updatedAt)",
  "function getUserAlert(address user) external view returns (uint256 targetPrice, bool alertAbove, bool executeAction, bool active, uint256 lastTriggered, uint256 cooldownPeriod)",
  "function isAlertTriggered(address user) external view returns (bool triggered, uint256 currentPrice)",
  "event PriceAlertTriggered(address indexed user, uint256 currentPrice, uint256 targetPrice)",
]);

const TRADING_MODULE_ABI = parseAbi([
  "function setTradeConfig((uint256 buyBelowPrice, uint256 sellAbovePrice, uint256 buyAmountUSDC, uint256 sellAmountETH, uint24 poolFee, uint256 slippageBps, bool active) config) external",
  "function getTradeConfig(address user) external view returns (uint256 buyBelowPrice, uint256 sellAbovePrice, uint256 buyAmountUSDC, uint256 sellAmountETH, uint24 poolFee, uint256 slippageBps, bool active)",
]);

const RISK_MODULE_ABI = parseAbi([
  "function setRiskParams(uint256 stopLossPrice, uint256 dailyMaxLossUSD) external",
  "function getRiskParams(address user) external view returns (uint256 stopLossPrice, uint256 dailyMaxLossUSD, uint256 dailyLossAccrued, uint256 lastResetTime, bool automationDisabled)",
  "function resumeAutomation() external",
  "function disableMyAutomation() external",
  "function isAutomationAllowed(address user) external view returns (bool)",
]);

// ─── Hooks ────────────────────────────────────────────────────────────────────

/**
 * Hook: Register as a Guardian user
 * @param delegate - optional AI agent wallet (Bankr) or EOA
 */
export function useRegisterUser() {
  const { writeContractAsync, isPending, isSuccess } = useWriteContract();

  const register = async (delegate = "0x0000000000000000000000000000000000000000") => {
    return writeContractAsync({
      address: ADDRESSES.guardianCore,
      abi: GUARDIAN_CORE_ABI,
      functionName: "registerUser",
      args: [delegate],
    });
  };

  return { register, isPending, isSuccess };
}

/**
 * Hook: Read user registration info
 */
export function useUserInfo(address) {
  return useReadContract({
    address: ADDRESSES.guardianCore,
    abi: GUARDIAN_CORE_ABI,
    functionName: "getUserInfo",
    args: [address],
    query: { enabled: !!address },
  });
}

/**
 * Hook: Get current ETH/USD price from Chainlink via contract
 */
export function useEthPrice() {
  const { data, refetch } = useReadContract({
    address: ADDRESSES.priceModule,
    abi: PRICE_MODULE_ABI,
    functionName: "getLatestPrice",
    query: { refetchInterval: 15_000 }, // refresh every 15s
  });

  return {
    price: data ? Number(data[0]) / 1e8 : null,
    updatedAt: data ? new Date(Number(data[1]) * 1000) : null,
    refetch,
  };
}

/**
 * Hook: Set a price alert
 */
export function useSetPriceAlert() {
  const { writeContractAsync, isPending } = useWriteContract();

  const setAlert = async ({
    targetPriceUSD,  // e.g. 2000 for $2000
    alertAbove,       // true = alert when above
    executeAction,    // true = trigger trade
    cooldownMinutes = 60,
  }) => {
    const targetPrice = BigInt(Math.round(targetPriceUSD * 1e8));
    const cooldown = BigInt(cooldownMinutes * 60);

    return writeContractAsync({
      address: ADDRESSES.priceModule,
      abi: PRICE_MODULE_ABI,
      functionName: "setPriceAlert",
      args: [targetPrice, alertAbove, executeAction, cooldown],
    });
  };

  return { setAlert, isPending };
}

/**
 * Hook: Get user's current price alert
 */
export function useUserPriceAlert(address) {
  const { data } = useReadContract({
    address: ADDRESSES.priceModule,
    abi: PRICE_MODULE_ABI,
    functionName: "getUserAlert",
    args: [address],
    query: { enabled: !!address },
  });

  if (!data) return { alert: null };

  return {
    alert: {
      targetPriceUSD: Number(data[0]) / 1e8,
      alertAbove: data[1],
      executeAction: data[2],
      active: data[3],
      lastTriggered: data[4] ? new Date(Number(data[4]) * 1000) : null,
      cooldownSeconds: Number(data[5]),
    },
  };
}

/**
 * Hook: Configure trading automation
 */
export function useSetTradeConfig() {
  const { writeContractAsync, isPending } = useWriteContract();

  const setConfig = async ({
    buyBelowPriceUSD,  // e.g. 1800
    sellAbovePriceUSD, // e.g. 2500
    buyAmountUSDC,     // e.g. 100 (USDC)
    sellAmountETH,     // e.g. 0.1 (ETH)
    poolFee = 3000,    // 500 | 3000 | 10000
    slippageBps = 50,  // 50 = 0.5%
  }) => {
    return writeContractAsync({
      address: ADDRESSES.tradingModule,
      abi: TRADING_MODULE_ABI,
      functionName: "setTradeConfig",
      args: [{
        buyBelowPrice:  BigInt(Math.round(buyBelowPriceUSD * 1e8)),
        sellAbovePrice: BigInt(Math.round(sellAbovePriceUSD * 1e8)),
        buyAmountUSDC:  parseUnits(String(buyAmountUSDC), 6),
        sellAmountETH:  parseUnits(String(sellAmountETH), 18),
        poolFee:        poolFee,
        slippageBps:    BigInt(slippageBps),
        active:         true,
      }],
    });
  };

  return { setConfig, isPending };
}

/**
 * Hook: Configure risk management
 */
export function useSetRiskParams() {
  const { writeContractAsync, isPending } = useWriteContract();

  const setRisk = async ({
    stopLossPriceUSD,  // e.g. 1500 → sell everything if ETH hits $1500
    dailyMaxLossUSD,   // e.g. 500 → pause if more than $500 lost today
  }) => {
    return writeContractAsync({
      address: ADDRESSES.riskModule,
      abi: RISK_MODULE_ABI,
      functionName: "setRiskParams",
      args: [
        BigInt(Math.round(stopLossPriceUSD * 1e8)),
        BigInt(Math.round(dailyMaxLossUSD * 1e8)),
      ],
    });
  };

  return { setRisk, isPending };
}

/**
 * Hook: Get risk status
 */
export function useRiskStatus(address) {
  const { data: allowed } = useReadContract({
    address: ADDRESSES.riskModule,
    abi: RISK_MODULE_ABI,
    functionName: "isAutomationAllowed",
    args: [address],
    query: { enabled: !!address, refetchInterval: 10_000 },
  });

  const { data: params } = useReadContract({
    address: ADDRESSES.riskModule,
    abi: RISK_MODULE_ABI,
    functionName: "getRiskParams",
    args: [address],
    query: { enabled: !!address },
  });

  return {
    automationAllowed: allowed ?? true,
    stopLossPriceUSD: params ? Number(params[0]) / 1e8 : null,
    dailyMaxLossUSD:  params ? Number(params[1]) / 1e8 : null,
    dailyLossUSD:     params ? Number(params[2]) / 1e8 : null,
    automationDisabled: params ? params[4] : false,
  };
}

/**
 * Hook: Resume automation after risk halt
 */
export function useResumeAutomation() {
  const { writeContractAsync, isPending } = useWriteContract();

  const resume = () =>
    writeContractAsync({
      address: ADDRESSES.riskModule,
      abi: RISK_MODULE_ABI,
      functionName: "resumeAutomation",
    });

  return { resume, isPending };
}

/**
 * Hook: Watch for price alert triggers in realtime
 */
export function useWatchPriceAlerts(onAlert) {
  useWatchContractEvent({
    address: ADDRESSES.priceModule,
    abi: PRICE_MODULE_ABI,
    eventName: "PriceAlertTriggered",
    onLogs: (logs) => {
      logs.forEach(log => {
        onAlert({
          user: log.args.user,
          currentPriceUSD: Number(log.args.currentPrice) / 1e8,
          targetPriceUSD:  Number(log.args.targetPrice)  / 1e8,
          txHash: log.transactionHash,
        });
      });
    },
  });
}
