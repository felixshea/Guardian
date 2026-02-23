/**
 * Guardian Offchain Monitor Bot
 * 
 * Listens to all Guardian contract events and sends notifications
 * via Telegram and webhooks. Runs as a persistent Node.js process.
 * 
 * Usage:
 *   npm install viem dotenv node-telegram-bot-api
 *   node bot/monitor.js
 */

import { createPublicClient, http, parseAbi, webSocketPublicActions } from "viem";
import { base } from "viem/chains";
import TelegramBot from "node-telegram-bot-api";
import dotenv from "dotenv";
dotenv.config();

// ─── Config ──────────────────────────────────────────────────────────────────
const GUARDIAN_CORE_ADDRESS   = process.env.GUARDIAN_CORE_ADDRESS;
const PRICE_MODULE_ADDRESS    = process.env.PRICE_MODULE_ADDRESS;
const WALLET_MODULE_ADDRESS   = process.env.WALLET_MODULE_ADDRESS;
const TRADING_MODULE_ADDRESS  = process.env.TRADING_MODULE_ADDRESS;
const RISK_MODULE_ADDRESS     = process.env.RISK_MODULE_ADDRESS;
const BASE_RPC_WS             = process.env.BASE_RPC_WS || "wss://base-mainnet.g.alchemy.com/v2/YOUR_KEY";
const WEBHOOK_URL             = process.env.NOTIFICATION_WEBHOOK_URL;

// ─── Telegram Setup ───────────────────────────────────────────────────────────
const bot = process.env.TELEGRAM_BOT_TOKEN
  ? new TelegramBot(process.env.TELEGRAM_BOT_TOKEN, { polling: false })
  : null;

async function notify(user, title, message) {
  const text = `🛡️ *Guardian Alert*\n\n*${title}*\n${message}\n\nWallet: \`${user.slice(0,6)}...${user.slice(-4)}\``;

  if (bot && process.env.TELEGRAM_CHAT_ID) {
    await bot.sendMessage(process.env.TELEGRAM_CHAT_ID, text, { parse_mode: "Markdown" });
  }

  if (WEBHOOK_URL) {
    await fetch(WEBHOOK_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ user, title, message, timestamp: Date.now() }),
    }).catch(console.error);
  }

  console.log(`[${new Date().toISOString()}] ${title} → ${user}: ${message}`);
}

// ─── ABI Fragments ────────────────────────────────────────────────────────────
const priceAbi = parseAbi([
  "event PriceAlertTriggered(address indexed user, uint256 currentPrice, uint256 targetPrice)",
  "event PriceAlertSet(address indexed user, uint256 targetPrice, bool alertAbove)",
]);

const walletAbi = parseAbi([
  "event LargeTransferDetected(address indexed wallet, address indexed from, uint256 amount)",
  "event WeeklyReportEmitted(address indexed wallet, uint256 ethBalance, uint256 timestamp)",
]);

const tradingAbi = parseAbi([
  "event TradeBuyExecuted(address indexed user, uint256 usdcSpent, uint256 ethReceived)",
  "event TradeSellExecuted(address indexed user, uint256 ethSold, uint256 usdcReceived)",
  "event TradeSkipped(address indexed user, string reason)",
]);

const riskAbi = parseAbi([
  "event StopLossTriggered(address indexed user, uint256 price)",
  "event DailyLossLimitReached(address indexed user, uint256 totalLoss)",
  "event AutomationResumed(address indexed user)",
]);

const coreAbi = parseAbi([
  "event UserRegistered(address indexed user, address indexed delegate)",
  "event FeeCollected(address indexed user, uint256 amount)",
]);

// ─── Client Setup ─────────────────────────────────────────────────────────────
const client = createPublicClient({
  chain: base,
  transport: http(process.env.BASE_RPC_URL),
});

// ─── Event Watchers ───────────────────────────────────────────────────────────
function startWatchers() {
  console.log("🚀 Guardian Monitor Bot starting...");

  // Price alerts
  client.watchContractEvent({
    address: PRICE_MODULE_ADDRESS,
    abi: priceAbi,
    eventName: "PriceAlertTriggered",
    onLogs: (logs) => logs.forEach(log => {
      const { user, currentPrice, targetPrice } = log.args;
      const priceUSD = Number(currentPrice) / 1e8;
      const targetUSD = Number(targetPrice) / 1e8;
      notify(user, "🔔 Price Alert Triggered",
        `ETH is $${priceUSD.toFixed(2)} (target: $${targetUSD.toFixed(2)})`);
    }),
    onError: console.error,
  });

  // Large transfer detection
  client.watchContractEvent({
    address: WALLET_MODULE_ADDRESS,
    abi: walletAbi,
    eventName: "LargeTransferDetected",
    onLogs: (logs) => logs.forEach(log => {
      const { wallet, from, amount } = log.args;
      const ethAmount = Number(amount) / 1e18;
      notify(wallet, "💸 Large Transfer Received",
        `${ethAmount.toFixed(4)} ETH received from ${from.slice(0,8)}...`);
    }),
    onError: console.error,
  });

  // Weekly reports
  client.watchContractEvent({
    address: WALLET_MODULE_ADDRESS,
    abi: walletAbi,
    eventName: "WeeklyReportEmitted",
    onLogs: (logs) => logs.forEach(log => {
      const { wallet, ethBalance } = log.args;
      const bal = Number(ethBalance) / 1e18;
      notify(wallet, "📊 Weekly Balance Report",
        `ETH balance: ${bal.toFixed(6)} ETH`);
    }),
    onError: console.error,
  });

  // Trade executions
  client.watchContractEvent({
    address: TRADING_MODULE_ADDRESS,
    abi: tradingAbi,
    eventName: "TradeBuyExecuted",
    onLogs: (logs) => logs.forEach(log => {
      const { user, usdcSpent, ethReceived } = log.args;
      notify(user, "🟢 Buy Executed",
        `Bought ${(Number(ethReceived)/1e18).toFixed(6)} ETH for ${(Number(usdcSpent)/1e6).toFixed(2)} USDC`);
    }),
    onError: console.error,
  });

  client.watchContractEvent({
    address: TRADING_MODULE_ADDRESS,
    abi: tradingAbi,
    eventName: "TradeSellExecuted",
    onLogs: (logs) => logs.forEach(log => {
      const { user, ethSold, usdcReceived } = log.args;
      notify(user, "🔴 Sell Executed",
        `Sold ${(Number(ethSold)/1e18).toFixed(6)} ETH for ${(Number(usdcReceived)/1e6).toFixed(2)} USDC`);
    }),
    onError: console.error,
  });

  // Risk events
  client.watchContractEvent({
    address: RISK_MODULE_ADDRESS,
    abi: riskAbi,
    eventName: "StopLossTriggered",
    onLogs: (logs) => logs.forEach(log => {
      const { user, price } = log.args;
      notify(user, "🚨 STOP LOSS TRIGGERED",
        `ETH hit $${(Number(price)/1e8).toFixed(2)} — automation disabled, emergency sell initiated`);
    }),
    onError: console.error,
  });

  client.watchContractEvent({
    address: RISK_MODULE_ADDRESS,
    abi: riskAbi,
    eventName: "DailyLossLimitReached",
    onLogs: (logs) => logs.forEach(log => {
      const { user, totalLoss } = log.args;
      notify(user, "⚠️ Daily Loss Limit Hit",
        `Total loss today: $${(Number(totalLoss)/1e8).toFixed(2)} — trading paused`);
    }),
    onError: console.error,
  });

  console.log("✅ All event watchers active. Listening to Base...\n");
}

// ─── Health Check ─────────────────────────────────────────────────────────────
async function healthCheck() {
  try {
    const block = await client.getBlockNumber();
    console.log(`[Health] Latest block: ${block}`);
  } catch (e) {
    console.error("[Health] RPC error:", e.message);
    process.exit(1);
  }
}

// ─── Entry Point ──────────────────────────────────────────────────────────────
await healthCheck();
startWatchers();
setInterval(healthCheck, 60_000); // health check every minute
