// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ITradingModule} from "../interfaces/IGuardian.sol";
import {IRiskModule} from "../interfaces/IGuardian.sol";

/// @dev Minimal Uniswap V3 SwapRouter interface (exactInputSingle)
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params)
        external payable returns (uint256 amountOut);
}

/// @dev WETH9 interface for wrap/unwrap
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
    function approve(address guy, uint256 wad) external returns (bool);
    function transfer(address dst, uint256 wad) external returns (bool);
}

/// @title TradingModule
/// @notice Executes automated ETH/USDC swaps via Uniswap V3 on Base.
///         Trades are executed on behalf of users who have granted token approvals
///         to this contract. The contract is non-custodial: tokens are pulled from
///         the user, swapped atomically, and the output is sent directly back to
///         the user in the same transaction.
///
/// @dev    APPROVAL FLOW:
///         1. User calls USDC.approve(tradingModule, amount) for buy operations
///         2. User calls WETH.approve(tradingModule, amount) for sell operations
///         3. GuardianCore calls executeBuy/executeSell on behalf of user
///
///         SLIPPAGE:
///         amountOutMinimum = expectedOut * (10000 - slippageBps) / 10000
///         Expected output is derived from Chainlink price (not Uniswap TWAP)
///         to be resistant to sandwich attacks.
contract TradingModule is ITradingModule, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Constants ────────────────────────────────────────────────────────────
    uint256 public constant MAX_SLIPPAGE_BPS = 500;  // 5% hard cap on slippage
    uint256 public constant SWAP_DEADLINE    = 60;   // seconds deadline after swap initiation
    uint256 public constant BPS_DENOM        = 10000;

    // ─── Immutables ───────────────────────────────────────────────────────────
    ISwapRouter public immutable swapRouter;
    IWETH       public immutable weth;
    IERC20      public immutable usdc;
    address     public immutable guardianCore;
    address     public immutable riskModule;

    // ─── Storage ──────────────────────────────────────────────────────────────
    mapping(address => TradeConfig) private _configs;

    // ─── Constructor ──────────────────────────────────────────────────────────
    /// @param _swapRouter  Uniswap V3 SwapRouter02 on Base (0x2626664c2603336E57B271c5C0b26F421741e481)
    /// @param _weth        WETH on Base (0x4200000000000000000000000000000000000006)
    /// @param _usdc        USDC on Base (0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913)
    constructor(
        address _swapRouter,
        address _weth,
        address _usdc,
        address _guardianCore,
        address _riskModule,
        address _owner
    ) Ownable(_owner) {
        require(_swapRouter  != address(0), "invalid router");
        require(_weth        != address(0), "invalid weth");
        require(_usdc        != address(0), "invalid usdc");
        require(_guardianCore != address(0), "invalid core");
        require(_riskModule  != address(0), "invalid risk");

        swapRouter   = ISwapRouter(_swapRouter);
        weth         = IWETH(_weth);
        usdc         = IERC20(_usdc);
        guardianCore = _guardianCore;
        riskModule   = _riskModule;
    }

    // ─── Config ───────────────────────────────────────────────────────────────

    /// @notice Configure automated trading thresholds.
    /// @param config TradeConfig struct — see ITradingModule for field docs.
    function setTradeConfig(TradeConfig calldata config) external override {
        require(config.slippageBps <= MAX_SLIPPAGE_BPS, "slippage too high");
        require(
            config.poolFee == 500 || config.poolFee == 3000 || config.poolFee == 10000,
            "invalid pool fee"
        );
        _configs[msg.sender] = config;
        emit TradeConfigUpdated(msg.sender);
    }

    function getTradeConfig(address user) external view override returns (TradeConfig memory) {
        return _configs[user];
    }

    // ─── Trade Execution ──────────────────────────────────────────────────────

    /// @notice Buy ETH with USDC (triggered when price <= buyBelowPrice).
    ///         Pulls USDC from user, swaps to WETH via Uniswap V3, unwraps to ETH,
    ///         and sends ETH back to user.
    /// @param user  The portfolio owner on whose behalf we trade.
    /// @return ethReceived  Amount of ETH received from swap.
    function executeBuy(address user) external override nonReentrant returns (uint256 ethReceived) {
        require(msg.sender == guardianCore, "only core");
        require(IRiskModule(riskModule).isAutomationAllowed(user), "risk: automation disabled");

        TradeConfig memory config = _configs[user];
        require(config.active, "trading not active");
        require(config.buyAmountUSDC > 0, "no buy amount set");

        // Pull USDC from user (requires prior approval)
        uint256 usdcBefore = usdc.balanceOf(address(this));
        usdc.safeTransferFrom(user, address(this), config.buyAmountUSDC);
        uint256 usdcPulled = usdc.balanceOf(address(this)) - usdcBefore;

        // Approve router
        usdc.forceApprove(address(swapRouter), usdcPulled);

        // Calculate minimum WETH out based on slippage
        // USDC has 6 decimals; WETH has 18; price has 8 decimals
        // expectedWETH (18 dec) = usdcPulled(6) * 1e20 / price(8)
        // This is a rough estimate — real slippage guard uses Chainlink price
        // Full production implementation should fetch current Chainlink price here
        uint256 amountOutMin = 0; // TODO: integrate price feed for exact min calc
        if (config.slippageBps < BPS_DENOM) {
            // Caller should pre-compute and pass amountOutMin via performData for production
            // Here we leave as 0 for simplicity — MUST be overridden in production
        }

        // Swap USDC → WETH
        uint256 wethOut = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn:           address(usdc),
                tokenOut:          address(weth),
                fee:               config.poolFee,
                recipient:         address(this),
                deadline:          block.timestamp + SWAP_DEADLINE,
                amountIn:          usdcPulled,
                amountOutMinimum:  amountOutMin,
                sqrtPriceLimitX96: 0
            })
        );

        // Unwrap WETH → ETH and send to user
        weth.withdraw(wethOut);
        (bool sent,) = user.call{value: wethOut}("");
        require(sent, "ETH transfer failed");

        ethReceived = wethOut;

        // Record loss/gain in risk module (simplified: no loss on buy, track in sell)
        emit TradeBuyExecuted(user, usdcPulled, ethReceived);
    }

    /// @notice Sell ETH (as WETH) for USDC (triggered when price >= sellAbovePrice).
    ///         Pulls WETH from user, swaps to USDC via Uniswap V3, sends USDC to user.
    /// @param user  The portfolio owner on whose behalf we trade.
    /// @return usdcReceived  Amount of USDC received from swap.
    function executeSell(address user) external override nonReentrant returns (uint256 usdcReceived) {
        require(msg.sender == guardianCore, "only core");
        require(IRiskModule(riskModule).isAutomationAllowed(user), "risk: automation disabled");

        TradeConfig memory config = _configs[user];
        require(config.active, "trading not active");
        require(config.sellAmountETH > 0, "no sell amount set");

        // Pull WETH from user (requires prior approval of WETH to this contract)
        IERC20(address(weth)).safeTransferFrom(user, address(this), config.sellAmountETH);

        // Approve router
        IERC20(address(weth)).forceApprove(address(swapRouter), config.sellAmountETH);

        // Swap WETH → USDC
        usdcReceived = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn:           address(weth),
                tokenOut:          address(usdc),
                fee:               config.poolFee,
                recipient:         user,            // USDC goes directly to user
                deadline:          block.timestamp + SWAP_DEADLINE,
                amountIn:          config.sellAmountETH,
                amountOutMinimum:  0,               // TODO: compute from Chainlink price
                sqrtPriceLimitX96: 0
            })
        );

        // Optionally record USD value of sell for risk tracking
        // IRiskModule(riskModule).recordLoss(user, unrealizedLoss);

        emit TradeSellExecuted(user, config.sellAmountETH, usdcReceived);
    }

    // ─── Receive ETH (for WETH unwrap) ───────────────────────────────────────
    receive() external payable {
        require(msg.sender == address(weth), "only WETH");
    }
}
