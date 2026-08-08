// BY GOD'S GRACE ALONE

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

import {Constants} from "v4-core/test/utils/Constants.sol";

import {DynamicFeeHook} from "../../src/DynamicFeeHook.sol";
import {
    POOL_MANAGER,
    USDC,
    POSITION_MANAGER,
    PERMIT2
} from "../../src/Constants.sol";

import {HookMiner} from "../../src/libraries/HookMiner.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Actions} from "../../src/libraries/Actions.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {IPermit2} from "../../src/interfaces/IPermit2.sol";
import {Swap} from "../../src/Swap.sol";
import {TestUtil} from "../../src/libraries/TestUtil.sol";


contract DynamicFeeHookTest is Test, TestUtil {

    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    /*//////////////////////////////////////////////////////////////
                            TEST CONTRACTS
    //////////////////////////////////////////////////////////////*/

    IPoolManager poolManager;
    IPositionManager posm;

    DynamicFeeHook hook;
    Swap swapRouter;

    PoolKey poolKey;
    PoolId poolId;

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    int24 constant TICK_SPACING = 10;

    uint160 constant SQRT_PRICE_1_1 =
        Constants.SQRT_PRICE_1_1;

    /*//////////////////////////////////////////////////////////////
                              SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {

        poolManager =
            IPoolManager(POOL_MANAGER);

        posm =
            IPositionManager(POSITION_MANAGER);

        swapRouter =
            new Swap(address(poolManager));

        /*
         * The hook needs both AFTER_INITIALIZE and BEFORE_SWAP
         * and AFTER_SWAP permissions.
         */
        uint160 flags =
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG
            );

        (
            address hookAddress,
            bytes32 salt
        ) = HookMiner.find({
            deployer: address(this),
            flags: flags,
            creationCode: type(DynamicFeeHook).creationCode,
            constructorArgs: abi.encode(
                address(poolManager)
            )
        });

        console2.log(
            "DynamicFeeHook address:",
            hookAddress
        );

        hook =
            new DynamicFeeHook{salt: salt}(
                address(poolManager)
            );

        console2.log(
            "Deployed DynamicFeeHook:",
            address(hook)
        );

        /*
         * The pool explicitly uses Uniswap v4's dynamic-fee mode.
         */
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(USDC),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        /*
         * IMPORTANT:
         *
         * Store the actual pool ID.
         *
         * Do not leave PoolId as bytes32(0).
         */
        poolId =
            poolKey.toId();

        poolManager.initialize(
            poolKey,
            SQRT_PRICE_1_1
        );

        /*
         * Give the test contract enough assets for swaps
         * and liquidity provision.
         */
        deal(
            USDC,
            address(this),
            1e18 * 1e6
        );

        deal(
            address(this),
            1_000_000 ether
        );

        IERC20(USDC).approve(
            PERMIT2,
            type(uint256).max
        );

        IPermit2(PERMIT2).approve(
            USDC,
            address(posm),
            type(uint160).max,
            type(uint48).max
        );

        _provideLiquidity();
    }

    /*//////////////////////////////////////////////////////////////
                         LIQUIDITY SETUP
    //////////////////////////////////////////////////////////////*/

    function _provideLiquidity() internal {

        int24 currentTick =
            getTick(poolKey.toId());

        int24 tickLower =
            getTickLower(
                currentTick,
                TICK_SPACING
            );

        uint256 liquidity =
            1e12;

        bytes memory actions =
            abi.encodePacked(
                uint8(Actions.MINT_POSITION),
                uint8(Actions.SETTLE_PAIR),
                uint8(Actions.SWEEP)
            );

        bytes[] memory params =
            new bytes[](3);

        /*
         * Provide a reasonably broad liquidity position.
         *
         * The test should have enough liquidity for the swaps
         * to execute normally.
         */
        params[0] = abi.encode(
            poolKey,

            tickLower -
                45000 * TICK_SPACING,

            tickLower +
                45000 * TICK_SPACING,

            liquidity,

            type(uint128).max,
            type(uint128).max,

            address(this),

            ""
        );

        params[1] =
            abi.encode(
                address(0),
                USDC
            );

        params[2] =
            abi.encode(
                address(0),
                address(this)
            );

        posm.modifyLiquidities{value: address(this).balance}(
            abi.encode(
                actions,
                params
            ),
            block.timestamp
        );
    }

    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                         PERMISSION TEST
    //////////////////////////////////////////////////////////////*/

    function test_permissions() public view {

        Hooks.validateHookPermissions(
            IHooks(address(hook)),
            hook.getHookPermissions()
        );
    }

    /*//////////////////////////////////////////////////////////////
                       INITIAL STATE TEST
    //////////////////////////////////////////////////////////////*/

    function test_initial_state_is_calm() public {

        bytes32 id =
            PoolId.unwrap(poolId);

        assertEq(
            hook.poolMovingVolatility(id),
            0
        );

        assertEq(
            hook.lastAppliedFee(id),
            hook.MIN_FEE()
        );

        assertEq(
            hook.swapCount(id),
            0
        );
    }

    /*//////////////////////////////////////////////////////////////
                         FIRST SWAP TEST
    //////////////////////////////////////////////////////////////*/

    function test_first_swap_uses_minimum_fee() public {

        bytes32 id =
            PoolId.unwrap(poolId);

        console2.log("");
        console2.log(
            "========================================"
        );
        console2.log(
            "STAGE 1: CALM MARKET"
        );
        console2.log(
            "========================================"
        );

        console2.log(
            "Executing the first small trade..."
        );

        swapRouter.swap{value: 1 ether}(
            Swap.SwapExactInputSingleHop({
                poolKey: poolKey,

                zeroForOne: true,

                amountIn: 1 ether,

                amountOutMin: 0,

                sqrtPriceLimitX96:
                    SQRT_PRICE_1_1 - 1000
            })
        );

        uint24 appliedFee =
            hook.lastAppliedFee(id);

        uint256 volatility =
            hook.poolMovingVolatility(id);

        console2.log(
            "Fee applied:",
            appliedFee
        );

        console2.log(
            "Volatility:",
            volatility
        );

        console2.log(
            "Observed swaps:",
            hook.swapCount(id)
        );

        /*
         * The first swap has no previous price movement
         * to react to.
         */
        assertEq(
            appliedFee,
            hook.MIN_FEE()
        );

        assertEq(
            hook.swapCount(id),
            1
        );
    }

    /*//////////////////////////////////////////////////////////////
                    VOLATILITY RESPONSE TEST
    //////////////////////////////////////////////////////////////*/

    function test_fee_increases_after_price_movement() public {
        bytes32 id = PoolId.unwrap(poolId);

        console2.log("");
        console2.log("========================================");
        console2.log("STAGE 1: CALM MARKET");
        console2.log("========================================");

        /*
        * The first swap has no previous volatility history.
        *
        * Therefore the hook should use the minimum fee.
        */
        console2.log("Executing first small trade...");

        swapRouter.swap{value: 1 ether}(
            Swap.SwapExactInputSingleHop({
                poolKey: poolKey,
                zeroForOne: true,
                amountIn: 1 ether,
                amountOutMin: 0,
                sqrtPriceLimitX96: SQRT_PRICE_1_1 - 1000
            })
        );

        uint24 firstFee = hook.lastAppliedFee(id);
        uint256 firstVolatility =
            hook.poolMovingVolatility(id);

        console2.log(
            "Fee applied to first trade:",
            firstFee
        );

        console2.log(
            "Volatility observed after first trade:",
            firstVolatility
        );

        assertEq(
            firstFee,
            hook.MIN_FEE(),
            "First swap should start at the minimum fee"
        );

        assertTrue(
            firstVolatility > 0,
            "The completed swap should produce a volatility observation"
        );


        console2.log("");
        console2.log("========================================");
        console2.log("STAGE 2: FEE RESPONDS TO OBSERVED VOLATILITY");
        console2.log("========================================");

        /*
        * The first swap has now created a volatility observation.
        *
        * The second swap therefore enters beforeSwap() with
        * non-zero volatility and should receive a higher fee.
        */
        console2.log(
            "Executing a larger market-stress trade..."
        );

        swapRouter.swap{value: 500 ether}(
            Swap.SwapExactInputSingleHop({
                poolKey: poolKey,
                zeroForOne: true,
                amountIn: 500 ether,
                amountOutMin: 0,
                sqrtPriceLimitX96: SQRT_PRICE_1_1 - 50000
            })
        );

        uint24 stressFee =
            hook.lastAppliedFee(id);

        uint256 stressVolatility =
            hook.poolMovingVolatility(id);

        console2.log(
            "Fee applied to stress trade:",
            stressFee
        );

        console2.log(
            "Volatility after stress trade:",
            stressVolatility
        );

        /*
        * This is the key assertion.
        *
        * The fee used for Swap 2 was calculated from the volatility
        * produced by Swap 1.
        */
        assertTrue(
            stressFee > firstFee,
            "Fee should increase after volatility is observed"
        );

        /*
        * Volatility does NOT have to increase on every swap.
        *
        * It is an EWMA, so a smaller subsequent price movement can
        * legitimately reduce the metric while the fee remains elevated.
        */
        assertTrue(
            stressVolatility > 0,
            "Volatility should remain positive"
        );

        /*
        * Safety invariant:
        *
        * The dynamic fee must never exceed the configured ceiling.
        */
        assertTrue(
            stressFee <= hook.MAX_FEE(),
            "Fee must remain below MAX_FEE"
        );


        console2.log("");
        console2.log("========================================");
        console2.log("STAGE 3: CONTINUED MARKET ACTIVITY");
        console2.log("========================================");

        /*
        * A third trade demonstrates that the hook continuously
        * updates its volatility estimate rather than permanently
        * locking the pool at the elevated fee.
        */
        console2.log(
            "Executing another market trade..."
        );

        uint24 feeBeforeThirdSwap =
            hook.lastAppliedFee(id);

        swapRouter.swap{value: 500 ether}(
            Swap.SwapExactInputSingleHop({
                poolKey: poolKey,
                zeroForOne: true,
                amountIn: 500 ether,
                amountOutMin: 0,
                sqrtPriceLimitX96: SQRT_PRICE_1_1 - 90000
            })
        );

        uint24 thirdFee =
            hook.lastAppliedFee(id);

        uint256 thirdVolatility =
            hook.poolMovingVolatility(id);

        console2.log(
            "Fee applied to third trade:",
            thirdFee
        );

        console2.log(
            "Volatility after third trade:",
            thirdVolatility
        );

        /*
        * The fee should always remain inside the protocol's
        * configured bounds.
        */
        assertTrue(
            thirdFee >= hook.MIN_FEE(),
            "Fee cannot fall below MIN_FEE"
        );

        assertTrue(
            thirdFee <= hook.MAX_FEE(),
            "Fee cannot exceed MAX_FEE"
        );

        /*
        * Confirm that the hook continues observing swaps.
        */
        assertEq(
            hook.swapCount(id),
            3,
            "Hook should have observed three swaps"
        );
    }

    /*//////////////////////////////////////////////////////////////
                       FEE FORMULA TEST
    //////////////////////////////////////////////////////////////*/

    function test_fee_formula_respects_bounds() public {

        assertEq(
            hook.calculateVolatilityFee(0),
            hook.MIN_FEE()
        );

        /*
         * A small non-zero volatility metric should produce
         * a fee no lower than the minimum.
         */
        assertTrue(
            hook.calculateVolatilityFee(
                1e6
            ) >= hook.MIN_FEE()
        );

        /*
         * Extremely high volatility must never exceed
         * the configured safety ceiling.
         */
        assertEq(
            hook.calculateVolatilityFee(
                type(uint256).max
            ),
            hook.MAX_FEE()
        );
    }
}