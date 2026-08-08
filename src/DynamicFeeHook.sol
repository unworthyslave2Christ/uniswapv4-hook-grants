// BY GOD'S GRACE ALONE

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title DynamicFeeHook
 *
 * @notice
 * Dynamically adjusts the Uniswap v4 LP fee according to recent pool
 * price movement.
 *
 * The hook maintains an exponentially weighted moving average (EWMA)
 * of observed tick movement:
 *
 *      swap
 *        ↓
 *   beforeSwap()
 *        ↓
 *   apply fee based on
 *   previously observed volatility
 *        ↓
 *      swap
 *        ↓
 *    afterSwap()
 *        ↓
 *   observe actual tick movement
 *        ↓
 *   update volatility metric
 *        ↓
 *   determine fee for next swap
 *
 * During calm markets, the fee approaches MIN_FEE.
 *
 * During periods of increasing price movement, the fee increases
 * progressively toward MAX_FEE.
 *
 * The objective is to provide LPs with additional fee compensation
 * during periods when adverse selection and LVR risk are elevated.
 */

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


contract DynamicFeeHook {

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error DynamicFeeHook__NotPoolManager();

    /*//////////////////////////////////////////////////////////////
                                LIBRARIES
    //////////////////////////////////////////////////////////////*/

    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    IPoolManager public immutable poolManager;

    /**
     * @notice Last pool tick observed by the hook.
     *
     * This is updated after each completed swap.
     */
    mapping(bytes32 => int24) public lastObservedTick;

    /**
     * @notice EWMA volatility metric for each pool.
     *
     * The metric is stored with VOLATILITY_SCALE precision.
     */
    mapping(bytes32 => uint256) public poolMovingVolatility;

    /**
     * @notice Fee that was selected for the most recent swap.
     *
     * This is primarily useful for observability and testing.
     */
    mapping(bytes32 => uint24) public lastAppliedFee;

    /**
     * @notice Number of swaps observed by the hook.
     *
     * Useful for testing and monitoring.
     */
    mapping(bytes32 => uint256) public swapCount;

    /*//////////////////////////////////////////////////////////////
                              FEE PARAMETERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev 0.30%.
     */
    uint24 public constant BASE_FEE = 3000;

    /**
     * @dev 5.00%.
     */
    uint24 public constant MAX_FEE = 50000;

    /**
     * @dev 0.05%.
     */
    uint24 public constant MIN_FEE = 500;

    /**
     * @dev EWMA smoothing parameter.
     *
     * Larger values make the volatility response smoother.
     */
    uint256 public constant SMOOTHING_FACTOR = 8;

    /**
     * @dev Fixed-point precision for the volatility metric.
     *
     * This prevents small tick movements from being lost because
     * Solidity performs integer division.
     */
    uint256 public constant VOLATILITY_SCALE = 1e6;

    /**
     * @dev Determines how aggressively volatility translates
     * into fee increases.
     *
     * The value is expressed against VOLATILITY_SCALE.
     */
    uint256 public constant FEE_SENSITIVITY = 120;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event VolatilityUpdated(
        bytes32 indexed poolId,
        int24 previousTick,
        int24 currentTick,
        uint256 tickMovement,
        uint256 volatility
    );

    event DynamicFeeApplied(
        bytes32 indexed poolId,
        uint24 fee,
        uint256 volatility
    );

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) {
            revert DynamicFeeHook__NotPoolManager();
        }

        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _poolManager) {
        poolManager = IPoolManager(_poolManager);

        Hooks.validateHookPermissions(
            IHooks(address(this)),
            getHookPermissions()
        );
    }

    /*//////////////////////////////////////////////////////////////
                         HOOK PERMISSIONS
    //////////////////////////////////////////////////////////////*/

    function getHookPermissions()
        public
        pure
        returns (Hooks.Permissions memory)
    {
        return Hooks.Permissions({
            beforeInitialize: false,

            afterInitialize: true,

            beforeAddLiquidity: false,
            afterAddLiquidity: false,

            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,

            beforeSwap: true,
            afterSwap: true,

            beforeDonate: false,
            afterDonate: false,

            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,

            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /*//////////////////////////////////////////////////////////////
                         AFTER INITIALIZE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Stores the initial pool tick.
     *
     * This gives the hook a reference point from which future
     * price movement can be measured.
     */
    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick
    )
        external
        onlyPoolManager
        returns (bytes4)
    {
        bytes32 poolId = PoolId.unwrap(key.toId());

        lastObservedTick[poolId] = tick;

        poolMovingVolatility[poolId] = 0;

        lastAppliedFee[poolId] = MIN_FEE;

        return IHooks.afterInitialize.selector;
    }

    /*//////////////////////////////////////////////////////////////
                            BEFORE SWAP
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Selects the fee for the current swap.
     *
     * IMPORTANT:
     *
     * beforeSwap executes before the current swap changes the pool
     * price. Therefore, this function uses the volatility measured
     * from previous swaps.
     */
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    )
        external
        onlyPoolManager
        returns (
            bytes4,
            BeforeSwapDelta,
            uint24
        )
    {
        bytes32 poolId = PoolId.unwrap(key.toId());

        uint256 volatility =
            poolMovingVolatility[poolId];

        uint24 dynamicFee =
            calculateVolatilityFee(volatility);

        lastAppliedFee[poolId] = dynamicFee;

        emit DynamicFeeApplied(
            poolId,
            dynamicFee,
            volatility
        );

        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,

            // Tell PoolManager to use our dynamic LP fee.
            dynamicFee | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    /*//////////////////////////////////////////////////////////////
                             AFTER SWAP
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Measures the price movement caused by the completed swap.
     *
     * This is deliberately performed after the swap so that the hook
     * measures the actual price movement rather than trying to predict
     * it before execution.
     */
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    )
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        bytes32 poolId = PoolId.unwrap(key.toId());

        // Read the pool tick after the swap has actually executed.
        (
            ,
            int24 currentTick,
            ,
        ) = poolManager.getSlot0(
            PoolId.wrap(poolId)
        );

        int24 previousTick = lastObservedTick[poolId];

        // Measure the absolute price movement caused by this swap.
        int256 tickDelta =
            int256(currentTick) -
            int256(previousTick);

        uint256 absoluteTickMovement =
            tickDelta >= 0
                ? uint256(tickDelta)
                : uint256(-tickDelta);

        // Read the previous EWMA volatility.
        uint256 previousVolatility =
            poolMovingVolatility[poolId];

        /*
        * Update the exponentially weighted moving average.
        *
        * The VOLATILITY_SCALE preserves precision when the observed
        * tick movement is small.
        */
        uint256 updatedVolatility =
            (
                previousVolatility *
                (SMOOTHING_FACTOR - 1)
                +
                absoluteTickMovement *
                VOLATILITY_SCALE
            )
            / SMOOTHING_FACTOR;

        poolMovingVolatility[poolId] =
            updatedVolatility;

        // This tick becomes the reference point for the next swap.
        lastObservedTick[poolId] =
            currentTick;

        swapCount[poolId]++;

        emit VolatilityUpdated(
            poolId,
            previousTick,
            currentTick,
            absoluteTickMovement,
            updatedVolatility
        );

        return (
            IHooks.afterSwap.selector,
            0
        );
    }
    /*//////////////////////////////////////////////////////////////
                         FEE CALCULATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Converts the volatility metric into an LP fee.
     *
     * The volatility metric is fixed-point scaled by 1e6.
     *
     * A zero-volatility pool receives MIN_FEE.
     *
     * As volatility increases, the fee moves progressively upward.
     *
     * MAX_FEE acts as a hard safety ceiling.
     */
    function calculateVolatilityFee(
        uint256 volatilityMetric
    )
        public
        pure
        returns (uint24)
    {
        if (volatilityMetric == 0) {
            return MIN_FEE;
        }

        uint256 feeIncrease =
            (
                volatilityMetric *
                FEE_SENSITIVITY
            )
            /
            VOLATILITY_SCALE;

        uint256 calculatedFee =
            BASE_FEE +
            feeIncrease;

        if (calculatedFee >= MAX_FEE) {
            return MAX_FEE;
        }

        if (calculatedFee <= MIN_FEE) {
            return MIN_FEE;
        }

        return uint24(calculatedFee);
    }
}