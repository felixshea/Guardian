# 🛡️ Guardian — AI Onchain Portfolio Guardian Agent

A production-grade, non-custodial DeFi automation system deployed on **Base (Ethereum L2)**.
Combines Chainlink Price Feeds, Chainlink Automation, Uniswap V3, and optional Bankr AI agent wallets.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                       GuardianCore.sol                       │
│  - User registry                                             │
│  - Chainlink Automation checkUpkeep / performUpkeep          │
│  - Module routing                                            │
│  - Fee accounting                                            │
└──────────┬───────────────────────────────────────────────────┘
           │ delegates to
    ┌──────┴──────────────────────────┐
    │                                  │
    ▼                                  ▼
PriceModule.sol               WalletModule.sol
- Chainlink ETH/USD feed      - Incoming transfer alerts
- Per-user alert thresholds   - Weekly scheduled reports
- Staleness checks            - Event-based (no funds held)
    │
    ▼
TradingModule.sol             RiskModule.sol
- Uniswap V3 swaps            - Stop-loss logic
- Buy ETH / Sell ETH          - Daily loss limits
- Slippage protection         - Automation kill switch
- Non-custodial pulls
```

---

## Module Descriptions

### GuardianCore.sol
The central hub. Manages user registration, delegates all actions to modules, and implements Chainlink Automation's `checkUpkeep`/`performUpkeep` interface. Uses a bitmask-per-user system to efficiently batch multiple actions per automation call. Maximum `MAX_USERS_PER_UPKEEP` = 10 users per upkeep transaction to stay within gas limits.

**Key design decisions:**
- Two-role auth: `owner` (protocol admin) + `trustedForwarders` (Chainlink, Bankr agents)
- `try/catch` on all module calls so one failing user doesn't revert the entire upkeep
- Pull-based fee collection in GUARDIAN token (optional)

### PriceModule.sol
Wraps Chainlink ETH/USD price feed with per-user alert configuration. Enforces staleness threshold (1 hour max) and requires `answeredInRound >= roundId` to catch stale Chainlink rounds. Alert cooldown prevents the same alert from firing repeatedly.

**Base Mainnet Chainlink Feed:** `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70`

### WalletModule.sol
Event-based monitoring — emits `LargeTransferDetected` and `WeeklyReportEmitted`. No funds held. For automatic large-transfer detection without user action, deploy a Chainlink Log Trigger watching WETH Transfer events filtered by user address.

### TradingModule.sol
Executes atomic swaps on Uniswap V3 via `exactInputSingle`. Tokens are pulled from the user, swapped, and output sent back to the user in one transaction. The contract never holds user tokens between calls.

**Important:** Users must pre-approve this contract for USDC (buy) and WETH (sell).

```
USDC → TradingModule → SwapRouter → WETH → unwrap → ETH → User
WETH → TradingModule → SwapRouter → USDC → User
```

**Base Mainnet Addresses:**
- SwapRouter02: `0x2626664c2603336E57B271c5C0b26F421741e481`
- WETH: `0x4200000000000000000000000000000000000006`
- USDC: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`

### RiskModule.sol
Acts as a gatekeeper checked before every automated action. Stop-loss permanently disables automation until the user manually calls `resumeAutomation()` — preventing any automation restart without explicit user consent. Daily loss limits auto-reset at midnight but also require manual resume if the limit was exceeded.

---

## Deployment Guide

### Prerequisites
```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
git clone https://github.com/yourorg/guardian && cd guardian
forge install OpenZeppelin/openzeppelin-contracts
forge install smartcontractkit/chainlink
cp .env.example .env  # fill in your values
```

### Base Sepolia (Testnet)
```bash
# Get testnet ETH from https://www.coinbase.com/faucets/base-ethereum-goerli-faucet

forge script script/Deploy.s.sol \
  --rpc-url base_sepolia \
  --broadcast \
  --verify \
  -vvvv
```

### Base Mainnet
```bash
# Simulate first (no broadcast)
forge script script/Deploy.s.sol \
  --rpc-url base_mainnet \
  --simulate \
  -vvvv

# Deploy (will prompt for confirmation)
forge script script/Deploy.s.sol \
  --rpc-url base_mainnet \
  --broadcast \
  --verify \
  --slow \
  -vvvv
```

### Post-Deployment: Register with Chainlink Automation
1. Go to https://automation.chain.link → Base network
2. Click "Register new Upkeep" → "Custom Logic"
3. Set **Target contract**: `GuardianCore` address
4. Fund with LINK tokens (~5 LINK for initial funding)
5. Set `checkData` to `abi.encode(uint256(0))` for offset 0 (first batch of users)
6. For >MAX_USERS_PER_UPKEEP users, register multiple upkeeps with different offsets

### Post-Deployment: Fund Chainlink Automation
```bash
# Transfer LINK to your Automation subscription
cast send $LINK_TOKEN_ADDRESS \
  "transfer(address,uint256)" \
  $AUTOMATION_REGISTRY_ADDRESS \
  5000000000000000000 \  # 5 LINK
  --private-key $PRIVATE_KEY \
  --rpc-url $BASE_RPC_URL
```

---

## Gas Optimization

| Technique | Savings |
|-----------|---------|
| Bitmask for action types (uint8) | ~200 gas/field vs bool mapping |
| `try/catch` in performUpkeep | Prevents full revert, saves wasted gas |
| Tight struct packing (User struct) | 1 slot for bool+bool+address+uint96 |
| `immutable` for module addresses in GuardianCore | ~2100 gas/access vs storage |
| MAX_USERS_PER_UPKEEP cap | Prevents out-of-gas failures |
| `forceApprove` for token allowances | Handles non-standard ERC20s |

**Estimated gas costs (Base network):**
- `registerUser`: ~85,000 gas (~$0.001)
- `setPriceAlert`: ~50,000 gas
- `performUpkeep` (10 users, 1 trade each): ~450,000 gas (~$0.005)

---

## Security Considerations

### Access Control
- `onlyCore` modifier on all module state-changing functions
- `trustedForwarders` mapping for Chainlink + Bankr agents
- Two-step ownership transfer (`Ownable2Step`) prevents accidental owner loss
- Delegate cannot be set by anyone other than the user themselves

### Reentrancy
- `ReentrancyGuard` on `GuardianCore.performUpkeep` and `TradingModule`
- WETH unwrap uses `receive()` with `require(msg.sender == address(weth))`
- Checks-Effects-Interactions pattern in all swap functions

### Oracle Security
- Chainlink feed staleness check: max 1 hour
- `answeredInRound >= roundId` check prevents stale rounds
- `answer > 0` check prevents negative/zero prices
- **TODO for production:** Add TWAP sanity check against Uniswap V3 pool

### Sandwich Attack Mitigation
- `amountOutMinimum` should be computed from Chainlink price, not Uniswap TWAP
- This is marked as TODO in the code — **must be implemented before mainnet**
- Add a max deviation check: revert if Chainlink price differs from pool price by >2%

### Token Approvals
- Users approve TradingModule directly, not GuardianCore
- Approvals can be revoked at any time via standard ERC20 `approve(tradingModule, 0)`
- Consider using Permit2 (Uniswap) for gasless approvals

### Emergency Procedures
- `GuardianCore.pause()` halts all automation (owner only)
- `RiskModule.disableMyAutomation()` available to any user
- Stop-loss requires manual `resumeAutomation()` to re-enable

---

## Security Audit Checklist

### Smart Contract Audits Required Before Mainnet
- [ ] Full Slither static analysis: `slither . --config-file slither.config.json`
- [ ] Echidna fuzzing on RiskModule loss accounting
- [ ] Formal verification of access control invariants
- [ ] Manual review of all external call patterns

### Specific Areas to Audit
- [ ] **Reentrancy**: Verify all ETH-transferring functions follow CEI
- [ ] **Oracle manipulation**: Chainlink heartbeat vs staleness threshold alignment
- [ ] **Slippage**: `amountOutMinimum = 0` is placeholder — MUST be fixed
- [ ] **Frontrunning**: performUpkeep is public; ensure economic incentives align
- [ ] **DoS**: What if one user's swap always reverts? (mitigated by try/catch)
- [ ] **Approval griefing**: Can a malicious token drain user funds? (only pre-approved tokens)
- [ ] **Delegate privilege escalation**: Confirm delegate cannot exceed user permissions
- [ ] **Integer overflow**: All math should use Solidity 0.8.x checked arithmetic
- [ ] **Event spoofing**: reportTransfer is caller-gated — verify this is sufficient
- [ ] **Fee accounting**: Verify fee collection cannot be double-counted

### Infrastructure Checklist
- [ ] Private key stored in HSM or MPC wallet (not .env in production)
- [ ] Chainlink Automation subscription has adequate LINK buffer (3+ months)
- [ ] Bot process has restart-on-crash (PM2 / systemd)
- [ ] RPC endpoint has fallback (Alchemy primary + Infura fallback)
- [ ] All contract addresses verified on Basescan
- [ ] Multisig as owner (Gnosis Safe) before mainnet launch

---

## Scalability

As user count grows:
1. **Partition users across multiple Automation jobs** using the `startIndex` offset in `checkData`
2. **Use The Graph** to index events and serve historical data to frontend
3. **Add CCIP** for cross-chain portfolio monitoring (Base + Optimism + Arbitrum)
4. **Upgrade to proxy pattern** (UUPS or Beacon Proxy) to push module upgrades without re-registering users
5. **ERC-4337 Account Abstraction** — users' smart wallets natively support delegate signatures without pre-approvals
6. **Batch approve via Permit2** — remove friction of two separate approve transactions

---

## Running the Monitor Bot

```bash
cd bot
npm install viem dotenv node-telegram-bot-api
node monitor.js
```

Use PM2 for production:
```bash
npm install -g pm2
pm2 start monitor.js --name guardian-bot
pm2 save && pm2 startup
```

---

## License
MIT
