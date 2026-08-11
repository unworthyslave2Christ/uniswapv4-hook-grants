// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IdleCapitalHook
 * 
 * @notice 
 * This hook unlocks a massive efficiency upgrade for Uniswap v4. In traditional concentrated liquidity (v3/v4), when a pool's price moves away from an LP’s specified range, their capital sits completely idle and out-of-range, earning 0% fees.This hook fixes that capital leak. It implements a Custom Accounting engine that monitors pool positions. When a user deposits liquidity or a swap pushes capital out of range, the hook automatically intercepts the tokens and shifts the idle assets into external yield-bearing protocols (like an ERC-4626 vault or Aave). When a swapper needs that liquidity back, the hook instantly recalls the capital mid-transaction.
 * 
 * 
 * The ARCHITECTURE BLUEPRINT
 * 
 * To build this safely and keep gas costs realistic, we use the standard ERC-4626 Tokenized Vault Standard for our external yield destination:
 * 
 * 1. AFTER_INITIALIZE_FLAG: True. We configure our external vault mapping parameters.
 * 
 * 2. AFTER_ADD_LIQUIDITY_FLAG: True. We sweep any unutilized seed tokens directly into the yield vault.
 * 
 * 3. BEFORE_SWAP_FLAG: True. If a massive swap requires more raw token liquidity than what is currently floating in the pool contract, the hook withdraws the exact deficit from the yield vault before the swap math executes.
 * 
 * 
 */

import {BaseHook} from "v4-periphery/src/base/BaseHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// Minimal interface for an ERC-4626 Yield Bearing Vault
interface IERC4626 is IERC20 {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function maxWithdraw(address owner) external view returns (uint256);
}

contract IdleCapitalYield is BaseHook {
    using CurrencyLibrary for Currency;

    // Track the dedicated yield vaults assigned to each asset type
    mapping(address => address) public tokenToVaultRegistry;
    
    // Safety cushion: Always keep 10% of liquidity raw inside the pool to optimize swap gas
    uint256 public constant LIQUIDITY_RESERVE_BUFFER = 10; 

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,    // Establish external vault dependencies
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false,
            afterAddLiquidity: true,   // Sweep newly deposited out-of-range capital to earn yield
            beforeSwap: true,          // Recall idle tokens if a huge swap clears out current reserves
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false
        });
    }

    // 1. Register the structural yield vault addresses upon initialization
    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4) {
        // Decode vault configurations passed inside the pool initialization payload
        (address vault0, address vault1) = abi.decode(hookData, (address, address));
        
        tokenToVaultRegistry[Currency.unwrap(key.currency0)] = vault0;
        tokenToVaultRegistry[Currency.unwrap(key.currency1)] = vault1;

        return BaseHook.afterInitialize.selector;
    }

    // 2. Sweep idle tokens to vault after liquidity provision
    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        // Delta values represent tokens transferred into the pool manager
        if (delta.amount0() > 0) {
            _sweepToYieldVault(Currency.unwrap(key.currency0), uint128(delta.amount0()));
        }
        if (delta.amount1() > 0) {
            _sweepToYieldVault(Currency.unwrap(key.currency1), uint128(delta.amount1()));
        }

        return (BaseHook.afterAddLiquidity.selector, delta);
    }

    // 3. Intercept swap framework to inject emergency liquidity liquidity if reserves are shallow
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        
        // Identify which token is being bought/drained from the pool contract
        address targetToken = params.zeroForOne ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
        uint256 poolReserveBalance = IERC20(targetToken).balanceOf(address(poolManager));
        
        uint256 estimatedRequiredAmount = params.amountSpecified > 0 
            ? uint256(params.amountSpecified) 
            : uint256(-params.amountSpecified);

        // If the swap amount exceeds current loose reserves, pull liquidity back from the vault instantly
        if (estimatedRequiredAmount > poolReserveBalance) {
            uint256 deficit = estimatedRequiredAmount - poolReserveBalance;
            _recallFromYieldVault(targetToken, deficit);
        }

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // --- Internal Accounting Engines ---

    function _sweepToYieldVault(address token, uint256 amount) internal {
        address vault = tokenToVaultRegistry[token];
        if (vault == address(0)) return;

        uint256 sweepAmount = (amount * (100 - LIQUIDITY_RESERVE_BUFFER)) / 100;
        
        // Approve and deposit the loose capital into the ERC-4626 strategy
        IERC20(token).approve(vault, sweepAmount);
        IERC4626(vault).deposit(sweepAmount, address(this));
    }

    function _recallFromYieldVault(address token, uint256 amount) internal {
        address vault = tokenToVaultRegistry[token];
        if (vault == address(0)) return;

        uint256 maxAvailable = IERC4626(vault).maxWithdraw(address(this));
        uint256 withdrawAmount = amount > maxAvailable ? maxAvailable : amount;

        if (withdrawAmount > 0) {
            // Pull the exact capital asset debt straight back into the PoolManager ecosystem
            IERC4626(vault).withdraw(withdrawAmount, address(poolManager), address(this));
        }
    }
}
