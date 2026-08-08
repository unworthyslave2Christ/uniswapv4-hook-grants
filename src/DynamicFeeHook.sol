// BY GOD'S GRACE ALONE

/**
 * @title the contract DynamicFeeHook enables increases in swap costs when volatility spikes to cushion against LVR. It is a hook that calculates the historical asset variance within the pool itself programmatically scaling the swap fee up during high volatility and down during market stability. The need for the hok stems from the fact that fixed fee tiers such as (uniswap v3's 0.05% or 0.30%) fail to protect LPs from Loss-Versus-Rebalancing (LVR) in the event of volatilities in prices, with this hook, fee generation for liquidity providers is maximized while maintaining competitive pricing during high-volume, steady-state periods, thus protecting liquidity providers from toxic arbitrage during high volatility. And indeed, this kind of hook is the most sought after in DeFi right now at it promises to to prevent LVR. It uses the onchain TWAP calculated over a short window as an oracle, using the price to calculate moving averages
 * @author 
 * @notice 
 */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// import {BaseHook} from "@uniswapv4-periphery/src/base/"

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

contract DynamicFeeHook {
    /*///////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////*/
    error DynamicFeeHook__NotPoolManager();

    /*///////////////////////////////////////////////////////////
                         LIBRARY USAGE
    //////////////////////////////////////////////////////////*/
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /*///////////////////////////////////////////////////////////
                         STATE VARIABLES
    //////////////////////////////////////////////////////////*/
    IPoolManager public immutable poolManager;

    // Keep track of the last block timestamp a swap occured to calculate time gaps
    mapping(bytes32 => int24) public lastObservedTick;

    // Track an internal moving average or "heat index" of volatility per pool
    mapping (bytes32 => uint256) public poolMovingVolatility;

    // architectural constraints for Uniswap v4 fees
    uint24 public constant BASE_FEE = 3000;         // 0.30% standard fee
    uint24 public constant MAX_FEE = 50000;         // 5.00% ceiling to prevent LVR during crashes
    uint24 public constant MIN_FEE = 500;           // 0.05% floor for stable, high-volume periods 
    uint256 public constant SMOOTHING_FACTOR = 8; // Decay parameter for the volatility metric

    /*///////////////////////////////////////////////////////////
                         MODIFIERS
    //////////////////////////////////////////////////////////*/
    modifier onlyPoolManager(){
        if (msg.sender != address(poolManager)) revert DynamicFeeHook__NotPoolManager();
        _;
    }

    /*///////////////////////////////////////////////////////////
                         FUNCTIONS
    //////////////////////////////////////////////////////////*/
    // address private immutable pool
    constructor(address _poolManager){
        poolManager = IPoolManager(_poolManager);
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }


    // 1. Telling the PoolManager which lifecycle functions this hook uses
    function getHookPermissions() 
        public 
        pure 
        returns (Hooks.Permissions memory)
    {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true, // it is a must to initialize the baseline tick tracking state
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // only intercept this hook before the swap happens
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // captures the initial slot0 price data when the pool is created
    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick
    )
        external
        onlyPoolManager
    returns (bytes4){
        bytes32 poolId = PoolId.unwrap(key.toId());
        lastObservedTick[poolId] = tick;
        return IHooks.afterInitialize.selector;
    }


    // The actual hook to execute right before a user swap occurs
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) 
        external
        onlyPoolManager
    returns (bytes4, BeforeSwapDelta, uint24){
        bytes32 poolId = PoolId.unwrap(key.toId());

        // fetch current pool tick directly from v4 pool  slot0 for given poolId
        (, int24 currentTick, , ) = poolManager.getSlot0(PoolId.wrap(poolId));

        // computing the absolute variance between trades
        int24 tickDelta = currentTick - lastObservedTick[poolId];
        uint256 absDelta = tickDelta >= 0 ? uint256(int256(tickDelta)) : uint256(int256(-tickDelta));
        
        // updating the exponential moving average of pool variance
        uint256 currentVolatility = poolMovingVolatility[poolId];
        uint256 updatedVolatility = ((currentVolatility * (SMOOTHING_FACTOR - 1)) + absDelta) / SMOOTHING_FACTOR;
        poolMovingVolatility[poolId] = updatedVolatility;

        // updating memory state for next incoming swap execution
        lastObservedTick[poolId] = currentTick;

        // calculate fee based on active variance
        uint24 dynamicFee = calculateVolatilityFee(updatedVolatility);
        
        // returning the function selector and pass the dynamic fee to the PoolManager 
        // The LPFeeLibrary.DYNAMIC_FEE_FLAG tells uniswap to override the standard fee
        return(
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            dynamicFee | LPFeeLibrary.DYNAMIC_FEE_FLAG
        );
    }

    // updatePlanName(uint256 planId, string calldata newName) 
    // updatePlanAmount(uint256 planId, uint256 newAmount)
    // updatePlanInterval(uint256 planId, uint256 newInterval)
    // updatePlanPaymentToken(uint256 planId, address newToken) 
    // updateTrialPeriod(uint256 planId, uint64 newTrialPeriod)
    // updateMaxSubscribers(uint256 planId, uint32 maxSubscribers)
    // setAutoRenewal(uint256 planId, bool enabled)

    // internal math logic for volatility calculation: converts price moves into fee tiers
    function calculateVolatilityFee(
        uint256 volatilityMetric
    ) 
        internal 
        pure 
    returns (uint24){
        if (volatilityMetric == 0) return MIN_FEE;

        // scale fee proportionally to moving volatility
        // For example, every unit of tick volatility adds roughly 0.01% (100 units) to the fee
        uint256 calculatedFee = BASE_FEE + (volatilityMetric * 120);

        // If arbitrageurs are driving the price violently across multiple blocks, the updatedVolatility metric explodes/increases/balloons rapidly, the fee aggressively hits the celing MAX_FEE, absorbing the arbitrage peofit and keeping that value trapped inside the pool for LPs

        if (calculatedFee > MAX_FEE) return MAX_FEE;

        // when market price randomness(noise) dies down and price deviation shrink, the exponential movinf average nativel pulls down to MIN_FEE,
        if (calculatedFee < MIN_FEE) return MIN_FEE;
    }

    
}