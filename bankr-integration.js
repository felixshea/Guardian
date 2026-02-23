/**
 * Bankr Agent Integration Guide
 * ─────────────────────────────
 * Bankr provides AI agent wallets that can sign transactions autonomously.
 * Here's how to wire a Bankr agent as your Guardian delegate.
 *
 * Flow:
 *   1. User creates a Bankr agent wallet → receives agent address
 *   2. User registers with GuardianCore, passing Bankr agent address as `delegate`
 *   3. User grants token approvals to TradingModule from their own wallet
 *   4. Bankr agent can now call GuardianCore-approved functions on behalf of user
 *
 * Bankr Agent API:
 *   - REST API at https://api.bankr.ai/v1
 *   - Webhooks for event-driven execution
 *   - Agent wallet signs transactions via MPC/Privy
 */

import dotenv from "dotenv";
dotenv.config();

const BANKR_API_BASE  = "https://api.bankr.ai/v1";
const BANKR_API_KEY   = process.env.BANKR_API_KEY;
const GUARDIAN_CORE   = process.env.GUARDIAN_CORE_ADDRESS;

// ─── Create a Bankr Agent Wallet ──────────────────────────────────────────────
export async function createBankrAgentWallet(userId) {
  const resp = await fetch(`${BANKR_API_BASE}/agent/wallet/create`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${BANKR_API_KEY}`,
    },
    body: JSON.stringify({
      userId,
      network: "base",
      label: "Portfolio Guardian Agent",
      permissions: ["sign_tx", "read_contract"],
    }),
  });

  const data = await resp.json();
  return {
    agentAddress: data.wallet.address,
    agentId: data.wallet.id,
  };
}

// ─── Instruct Bankr Agent to Execute Guardian Action ─────────────────────────
export async function dispatchAgentAction({
  agentId,
  action,          // "buy_eth" | "sell_eth" | "update_risk" | "report"
  targetUser,      // address of portfolio owner
  params = {},
}) {
  /**
   * Bankr agent will:
   * 1. Verify it is listed as delegate for `targetUser` in GuardianCore
   * 2. Sign and broadcast the corresponding transaction
   * 3. Return tx hash
   */

  const payload = {
    agentId,
    chain: "base",
    contract: GUARDIAN_CORE,
    action,
    targetUser,
    params,
    priority: action === "stop_loss" ? "urgent" : "normal",
  };

  const resp = await fetch(`${BANKR_API_BASE}/agent/dispatch`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${BANKR_API_KEY}`,
      "X-Webhook-Secret": process.env.BANKR_WEBHOOK_SECRET,
    },
    body: JSON.stringify(payload),
  });

  return resp.json();
}

// ─── Webhook Handler (Next.js / Express) ──────────────────────────────────────
// POST /api/bankr/webhook
export async function bankrWebhookHandler(req, res) {
  // Verify webhook authenticity
  const sig = req.headers["x-bankr-signature"];
  if (!verifyBankrSignature(req.body, sig, process.env.BANKR_WEBHOOK_SECRET)) {
    return res.status(401).json({ error: "Invalid signature" });
  }

  const { event, data } = req.body;

  switch (event) {
    case "price.alert.triggered":
      // Bankr received event from Guardian and is notifying us
      await dispatchAgentAction({
        agentId: data.agentId,
        action: data.alertAbove ? "sell_eth" : "buy_eth",
        targetUser: data.user,
      });
      break;

    case "risk.stop_loss.breached":
      // Emergency: trigger immediate sell
      await dispatchAgentAction({
        agentId: data.agentId,
        action: "stop_loss",
        targetUser: data.user,
      });
      break;

    case "tx.confirmed":
      console.log(`Tx confirmed: ${data.txHash} for user ${data.user}`);
      break;
  }

  res.json({ received: true });
}

function verifyBankrSignature(body, signature, secret) {
  // HMAC-SHA256 verification (production implementation)
  import crypto from "crypto";
  const expected = crypto
    .createHmac("sha256", secret)
    .update(JSON.stringify(body))
    .digest("hex");
  return signature === expected;
}

// ─── Setup Instructions ───────────────────────────────────────────────────────
/*
  BANKR INTEGRATION SETUP STEPS:

  1. Sign up at https://bankr.ai and create a project
  2. Get API key from dashboard → Settings → API Keys
  3. Create an agent wallet for your user:
       const { agentAddress } = await createBankrAgentWallet("user-123");

  4. User registers on GuardianCore with agent as delegate:
       await guardianCore.write.registerUser([agentAddress]);

  5. User approves tokens (from their own wallet):
       await usdc.write.approve([tradingModuleAddress, maxAmount]);
       await weth.write.approve([tradingModuleAddress, maxAmount]);

  6. Set up Bankr webhook pointing to your server:
       https://yourapp.com/api/bankr/webhook

  7. Configure Bankr to monitor Guardian contract events and dispatch accordingly.

  IMPORTANT:
  - The Bankr agent wallet CANNOT transfer user funds — it can only call
    approved functions on GuardianCore (which are gated by the risk module).
  - User maintains full custody at all times.
  - Revoke delegate at any time via: guardianCore.write.updateDelegate([ethers.ZeroAddress])
*/
