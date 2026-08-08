// BY GOD'S GRACE ALONE

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";

import {Constants} from "v4-core/test/utils/Constants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DynamicFeeHook} from "../../src/DynamicFeeHook.sol";
import {
    POOL_MANAGER,
    USDC,
    POSITION_MANAGER,
    PERMIT2
} from "../../src/Constants.sol";

import {HookMiner} from "../../src/libraries/HookMiner.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {IPermit2} from "../../src/interfaces/IPermit2.sol";
import {TestUtil} from "../../src/libraries/TestUtil.sol";
import {Swap} from "../../src/Swap.sol";


contract DynamicFeeHookTest is Test, TestUtil {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager poolManager;
    IPositionManager posm;
    DynamicFeeHook hook;

    PoolKey poolKey;
    PoolId poolId;

    Swap swapRouter;

    int24 constant TICK_SPACING = 10;
    uint160 public constant SQRT_PRICE_1_1 = Constants.SQRT_PRICE_1_1;

    function setUp() public {
        // ---------------------------------------------------------------------
        // 1. Connect to the Uniswap v4 PoolManager and supporting contracts.
        // ---------------------------------------------------------------------

        poolManager = IPoolManager(POOL_MANAGER);
        posm = IPositionManager(POSITION_MANAGER);

        swapRouter = new Swap(address(poolManager));

        // ---------------------------------------------------------------------
        // 2. Deploy the hook at an address with the permissions required by
        //    the hook: AFTER_INITIALIZE and BEFORE_SWAP.
        // ---------------------------------------------------------------------

        uint160 hookFlags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.BEFORE_SWAP_FLAG
        );

        (address hookAddress, bytes32 hookSalt) = HookMiner.find({
            deployer: address(this),
            flags: hookFlags,
            creationCode: type(DynamicFeeHook).creationCode,
            constructorArgs: abi.encode(address(poolManager))
        });

        console2.log("DynamicFeeHook address:", hookAddress);
        console2.logBytes32(hookSalt);

        hook = new DynamicFeeHook{salt: hookSalt}(address(poolManager));

        console2.log(
            "Deployed DynamicFeeHook:",
            address(hook)
        );

        // ---------------------------------------------------------------------
        // 3. Create a pool that explicitly uses Uniswap v4's dynamic-fee flag.
        //
        //    The hook will use BEFORE_SWAP to determine the appropriate fee
        //    according to the pool's observed volatility.
        // ---------------------------------------------------------------------

        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)), // Native ETH
            currency1: Currency.wrap(USDC),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        poolId = poolKey.toId();

        poolManager.initialize(
            poolKey,
            SQRT_PRICE_1_1
        );

        // ---------------------------------------------------------------------
        // 4. Fund the test account so it can provide liquidity and execute
        //    swaps against the pool.
        // ---------------------------------------------------------------------

        deal(USDC, address(this), 1e30 * 1e6);
        deal(address(this), 1_000_000 ether);

        // Allow Permit2 to transfer USDC on behalf of this test account.
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

        // ---------------------------------------------------------------------
        // 5. Add a wide liquidity position.
        //
        //    The position is intentionally wide so that the test focuses on
        //    the hook's dynamic-fee behavior rather than running out of
        //    liquidity during the volatility simulation.
        // ---------------------------------------------------------------------

        int24 currentTick = getTick(poolId);
        int24 tickLower = getTickLower(
            currentTick,
            TICK_SPACING
        );

        uint256 liquidity = 1e15;

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR),
            uint8(Actions.SWEEP)
        );

        bytes[] memory params = new bytes[](3);

        // Create a broad liquidity position around the current price.
        params[0] = abi.encode(
            poolKey,
            tickLower - 45_000 * TICK_SPACING,
            tickLower + 45_000 * TICK_SPACING,
            liquidity,
            type(uint128).max,
            type(uint128).max,
            address(this),
            ""
        );

        // Settle both currencies used by the position.
        params[1] = abi.encode(
            address(0),
            USDC
        );

        // Return any remaining native ETH to the test account.
        params[2] = abi.encode(
            address(0),
            address(this)
        );

        posm.modifyLiquidities{value: address(this).balance}(
            abi.encode(actions, params),
            block.timestamp
        );
    }

    receive() external payable {}

    // =========================================================================
    // Helper Functions
    // =========================================================================

    /**
     * @dev Reads the LP fee currently stored in the PoolManager's slot0 state.
     *
     * Note:
     * This is the PoolManager's stored LP fee. If the hook supplies a
     * per-swap fee override from beforeSwap(), that override is the fee used
     * for that swap and is not necessarily persisted in slot0.
     */
    function _getStoredPoolFee() internal view returns (uint24 lpFee) {
        (, , , lpFee) = poolManager.getSlot0(poolId);
    }

    // =========================================================================
    // Hook Permission Test
    // =========================================================================

    function test_permissions() public view {
        Hooks.validateHookPermissions(
            IHooks(address(hook)),
            hook.getHookPermissions()
        );
    }

    // =========================================================================
    // Initial State Test
    // =========================================================================

    function test_initial_state_is_calm() public view {
        // ---------------------------------------------------------------------
        // Before any trading takes place, the pool has experienced no
        // price movement. The hook should therefore observe zero volatility.
        // ---------------------------------------------------------------------

        uint256 currentVolatility =
            hook.poolMovingVolatility(
                PoolId.unwrap(poolId)
            );

        assertEq(
            currentVolatility,
            0,
            "Pool should begin with zero volatility"
        );

        console2.log(
            "Initial market volatility:",
            currentVolatility
        );
    }

    // =========================================================================
    // Dynamic Fee Escalation Test
    // =========================================================================

    function test_fee_escalation_during_market_crash() public {
        console2.log("");
        console2.log("========================================");
        console2.log(" DYNAMIC FEE VOLATILITY TEST");
        console2.log("========================================");

        // ---------------------------------------------------------------------
        // STAGE 1 — NORMAL MARKET ACTIVITY
        //
        // We begin with a relatively small retail-sized trade. The purpose of
        // this swap is to represent ordinary market activity where the price
        // should experience only a small disturbance.
        //
        // Expected behavior:
        // - Low price movement
        // - Low observed volatility
        // - Hook remains near its minimum fee
        // ---------------------------------------------------------------------

        console2.log("");
        console2.log("STAGE 1: NORMAL MARKET ACTIVITY");
        console2.log("----------------------------------------");
        console2.log("Executing a small retail trade...");

        swapRouter.swap{value: 1 ether}(
            Swap.SwapExactInputSingleHop({
                poolKey: poolKey,
                zeroForOne: true,
                amountIn: 1 ether,
                amountOutMin: 0,
                sqrtPriceLimitX96: SQRT_PRICE_1_1 - 1_000
            })
        );

        uint24 feeAfterSwap1 = _getStoredPoolFee();

        console2.log(
            "Stored LP fee after retail trade:",
            feeAfterSwap1
        );

        // ---------------------------------------------------------------------
        // STAGE 2 — MARKET STRESS
        //
        // We now simulate a large institutional sell-off. The significantly
        // larger order should create greater price movement and therefore
        // increase the volatility observed by the hook.
        //
        // Expected behavior:
        // - Greater price displacement
        // - Higher volatility
        // - Dynamic fee increases to compensate liquidity providers for
        //   increased market risk
        // ---------------------------------------------------------------------

        console2.log("");
        console2.log("STAGE 2: MARKET STRESS");
        console2.log("----------------------------------------");
        console2.log("Executing a large institutional sell-off...");

        swapRouter.swap{value: 500 ether}(
            Swap.SwapExactInputSingleHop({
                poolKey: poolKey,
                zeroForOne: true,
                amountIn: 500 ether,
                amountOutMin: 0,
                sqrtPriceLimitX96: SQRT_PRICE_1_1 - 50_000
            })
        );

        uint24 feeAfterSwap2 = _getStoredPoolFee();

        console2.log(
            "Stored LP fee after market stress:",
            feeAfterSwap2
        );

        // The dynamic fee should increase as market volatility increases.
        assertTrue(
            feeAfterSwap2 > feeAfterSwap1,
            "Fee should increase as volatility increases"
        );

        // ---------------------------------------------------------------------
        // STAGE 3 — EXTREME MARKET VOLATILITY
        //
        // Finally, we simulate a cascading sell-off. This represents an
        // extreme market event where successive large trades rapidly move
        // the pool price.
        //
        // Expected behavior:
        // - Volatility reaches an extreme level
        // - The hook protects LPs by applying its maximum fee
        // - The fee cannot exceed the configured safety ceiling
        // ---------------------------------------------------------------------

        console2.log("");
        console2.log("STAGE 3: EXTREME MARKET VOLATILITY");
        console2.log("----------------------------------------");
        console2.log("Executing a cascading panic sell...");

        swapRouter.swap{value: 300 ether}(
            Swap.SwapExactInputSingleHop({
                poolKey: poolKey,
                zeroForOne: true,
                amountIn: 300 ether,
                amountOutMin: 0,
                sqrtPriceLimitX96: SQRT_PRICE_1_1 - 90_000
            })
        );

        uint24 feeAfterSwap3 = _getStoredPoolFee();

        console2.log(
            "Stored LP fee after extreme volatility:",
            feeAfterSwap3
        );

        // The hook should enforce its configured maximum fee during extreme
        // volatility rather than allowing the fee to grow without bound.
        assertEq(
            feeAfterSwap3,
            hook.MAX_FEE(),
            "Extreme volatility should trigger MAX_FEE"
        );

        console2.log("");
        console2.log("========================================");
        console2.log(" VOLATILITY TEST COMPLETE");
        console2.log("========================================");
    }
}