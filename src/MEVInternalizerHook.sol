// BY GOD'S GRACE ALONE

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title MEVInternalizerHook
 * 
 * @notice 
 * This hook attacks a massive problem in DeFi: Toxic Arbitrage and Sandwich Bots stealing yield from Liquidity Providers (LPs). Instead of allowing external searcher bots to capture the arbitrage difference during market price swings, this hook internalizes the MEV by forcing sequential transactions in the same block to pay an explicit premium or premium auction fee, which is deposited back into the pool assets as a native protocol donation.
 * 
 * The ARCHITECTURE BLUEPRINT
 * 
 * To capture and penalize rapid block-level manipulation, this hook monitors chronological block metadata and transaction sequencing:
 * 1. BEFORE_SWAP_FLAG: True. We intercept the swap, check if a previous transaction already altered the pool price in this exact block, and apply an MEV premium.
 * 2. AFTER_SWAP_FLAG: True. We log the final pool state at the end of the transaction to catch the next bot in line.
 * 
 * 
 */

import {BaseHook} from "v4-periphery/src/base/BaseHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary
} from "v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";


contract MEVInternalizerHook {
    error MEVInternalizerHook__NotPoolManager;

    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    // Track block-level execution metrics to isolate flash loans and sandwich bots
    struct BlockTracker {
        uint256 blockNumber;
        int24 tickAtBlockStart;
        uint24 transactionIndex;
    }

    mapping (bytes32 => BlockTracker) public poolBlockRegistry;

    IPoolManager public immutable poolManager;

    // Captured MEV rewards are temporarily safely sequestered before distribution
    uint256 public constant MEV_PREMIUM_FEE = 15000; // Extra 1.50% penalty fee for back-to-back trades 

    constructor(address _poolManager) {
        poolManager = IPoolManager(_poolManager);

        Hooks.validateHookPermissions(
            IHooks(address(this)),
            getHookPermissions()
        );
        

    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) {
            revert MEVInternalizerHook__NotPoolManager();
        }

        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory){
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,       // Detect incoming back-to-back sandwich/arbitage trades
            afterSwap: true,        // Record transaction data to lock down the sequence
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false

        })
    }

    // 1. Intercept before swap to check for MEV signatures
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24){
          bytes32 poolId = key.toId();
          BlockTracker memory tracker = poolBlockRegistry[poolId];

          uint24 feeOverride = 0;

          // CRTICAL DEFI RADAR: Detect if another swap already happened in exact block  
          if (tracker.blockNumber == block.number){
            // Back-to-back trades inside the same block indicate arbitrage or a sandwich attack.
            // Override the fee to extract a premium from the searcher bot.
            feeOverride = MEV_PREMIUM_FEE | LPFeeLibrary.DYNAMIC_FEE_FLAG;
          } 

          return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            feeOverride
        );
    }


    // 2. Log final price metrics immediately after the transaction frame closes
    function afterSwap(
        address,
        PoolKey callda key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        bytes32 poolId = key.toId();
        (, int24 currentTick, , ) = poolManager.getSlot0(poolId);

        BlockTracker memory tracker = poolBlockRegistry[poolId];

        // Increment or initialize sequence tracking for the current block space
         if (tracker.blockNumber == block.number){
            tracker.transactionIndex += 1;
         } else {
            tracker.blockNumber = block.number;
            tracker.tickAtBlockStart = currentTick;
            tracker.transactionIndex = 0;
         }

         poolBlockRegistry[poolId] = tracker;

         return (IHooks.afterSwap.selector, 0);
    }
}

