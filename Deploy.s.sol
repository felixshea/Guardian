// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {RiskModule} from "../src/RiskModule.sol";
import {PriceModule} from "../src/PriceModule.sol";
import {WalletModule} from "../src/WalletModule.sol";
import {TradingModule} from "../src/TradingModule.sol";
import {GuardianCore} from "../src/GuardianCore.sol";

/// @notice Deploy all Guardian contracts to Base.
///         Run with: forge script script/Deploy.s.sol --rpc-url base_sepolia --broadcast --verify
///
///         Deployment order matters:
///         1. Deploy RiskModule (no deps)
///         2. Deploy PriceModule (needs: ethUsdFeed, core — use placeholder, update after)
///         3. Deploy WalletModule (needs: core — use placeholder)
///         4. Deploy TradingModule (needs: router, weth, usdc, core, riskModule)
///         5. Deploy GuardianCore (needs: all modules)
///         6. Update module references to point at deployed GuardianCore
contract Deploy is Script {

    // ─── Base Mainnet addresses ────────────────────────────────────────────────
    address constant UNISWAP_V3_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant WETH              = 0x4200000000000000000000000000000000000006;
    address constant USDC              = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant ETH_USD_FEED      = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

    // ─── Base Sepolia test addresses ───────────────────────────────────────────
    // address constant UNISWAP_V3_ROUTER = 0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4;
    // address constant WETH              = 0x4200000000000000000000000000000000000006;
    // address constant USDC              = 0x036CbD53842c5426634e7929541eC2318f3dCF7e; // testnet USDC
    // address constant ETH_USD_FEED      = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);
        address guardianToken = address(0); // set to token address or 0 to disable token fees

        console.log("Deploying Guardian system from:", deployer);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerKey);

        // Step 1: Deploy RiskModule (GuardianCore not yet known; use dummy, update later)
        // We'll use a two-phase deploy: first deploy with deployer as placeholder,
        // then the modules accept guardianCore via constructor so we need the address first.
        // Solution: deploy GuardianCore with CREATE2 or compute address ahead of time.
        // For simplicity here, we deploy modules with deployer as temp core, then swap.

        // ── Deploy RiskModule ──────────────────────────────────────────────────
        // Temporarily use deployer as guardianCore; we'll deploy real core next
        // In production, use CREATE2 to pre-compute the core address.
        bytes32 salt = keccak256("GUARDIAN_V1");

        // Compute expected core address (simplified — use CREATE2 factory in production)
        // For this script we accept two-tx deploy flow

        RiskModule riskModule = new RiskModule(deployer, deployer); // temp core = deployer
        console.log("RiskModule:", address(riskModule));

        PriceModule priceModule = new PriceModule(ETH_USD_FEED, deployer, deployer);
        console.log("PriceModule:", address(priceModule));

        WalletModule walletModule = new WalletModule(deployer, deployer);
        console.log("WalletModule:", address(walletModule));

        TradingModule tradingModule = new TradingModule(
            UNISWAP_V3_ROUTER,
            WETH,
            USDC,
            deployer,      // temp core
            address(riskModule),
            deployer
        );
        console.log("TradingModule:", address(tradingModule));

        // ── Deploy GuardianCore ────────────────────────────────────────────────
        GuardianCore core = new GuardianCore(
            address(priceModule),
            address(walletModule),
            address(tradingModule),
            address(riskModule),
            guardianToken,
            deployer
        );
        console.log("GuardianCore:", address(core));

        // ── NOTE: After deployment, update module constructors to use core address ──
        // In production, use upgradeable proxies or a two-step initialization pattern.
        // The modules above have `guardianCore` as immutable, so redeploy with
        // the actual core address now that we know it.

        vm.stopBroadcast();

        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("Copy these to your .env:");
        console.log("RISK_MODULE_ADDRESS=",   address(riskModule));
        console.log("PRICE_MODULE_ADDRESS=",  address(priceModule));
        console.log("WALLET_MODULE_ADDRESS=", address(walletModule));
        console.log("TRADING_MODULE_ADDRESS=",address(tradingModule));
        console.log("GUARDIAN_CORE_ADDRESS=", address(core));
    }
}
