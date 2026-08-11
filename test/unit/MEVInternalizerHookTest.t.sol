// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {MEVInternalizerHook} from "../src/MEVInternalizerHook.sol";

contract MEVInternalizerHookTest is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    MEVInternalizerHook hook;
    PoolKey poolKey;
    PoolId poolId;

    function setUp() public {
        // 1. Initialize the Uniswap V4 core environment
        deployFreshManagerAndRouters();
        deployMintAndApprove2Tokens();

        // 2. Setup the exact address flags required for Hook #2
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );

        // 3. Mine the deployment address salt
        bytes memory constructorArgs = abi.encode(manager);
        address hookAddress = deployCodeToAddress(
            "MEVInternalizerHook.sol:MEVInternalizerHook",
            constructorArgs,
            flags
        );
        hook = MEVInternalizerHook(hookAddress);

        // 4. Register the pool key with the dynamic fee flag turned on
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hook: hook
        });
        poolId = poolKey.toId();

        // 5. Initialize and seed deep liquidity
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 10_000 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        // Explicitly set an initial block height
        vm.roll(1000);
    }
            function test_isolated_trades_receive_standard_fee() public {
        console2.log("--- SIMULATING ORGANIC ISOLATED TRADES ---");

        // Swap 1 occurs at Block 1000
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: SQRT_PRICE_1_1 - 1000
            }),
            Deployers.HookData({testSettings: false, hookData: ZERO_BYTES}),
                ZERO_BYTES
            );
            (, , uint24 fee1, ) = manager.getPoolAndRemainingFee(poolKey);
            console2.log("Fee for Trade 1 (Block 1000):", fee1);

            // Advance to a brand new block space
            vm.roll(1001);

            // Swap 2 occurs at Block 1001
            swapRouter.swap(
                poolKey,
                IPoolManager.SwapParams({
                    zeroForOne: true,
                    amountSpecified: -1 ether,
                    sqrtPriceLimitX96: SQRT_PRICE_1_1 - 2000
                }),
                Deployers.HookData({testSettings: false, hookData: ZERO_BYTES}),
                ZERO_BYTES
            );
            (, , uint24 fee2, ) = manager.getPoolAndRemainingFee(poolKey);
            console2.log("Fee for Trade 2 (Block 1001):", fee2);

            // Since they were isolated, the hook should return 0 (falls back to pool base fee calculation)
            assertEq(fee1, 0);
            assertEq(fee2, 0);
        }

        function test_back_to_back_trades_trigger_mev_penalty() public {
            console2.log("--- SIMULATING BACK-TO-BACK MEV ATTACK ---");

            // Move to block 2000
            vm.roll(2000);

            // Transaction A: The Front-run swap or standard user swap hitting the block first
            swapRouter.swap(
                poolKey,
                IPoolManager.SwapParams({
                    zeroForOne: true,
                    amountSpecified: -1 ether,
                    sqrtPriceLimitX96: SQRT_PRICE_1_1 - 1000
                }),
                Deployers.HookData({testSettings: false, hookData: ZERO_BYTES}),
                ZERO_BYTES
            );
            (, , uint24 feeA, ) = manager.getPoolAndRemainingFee(poolKey);
            console2.log("Transaction A Fee (First in Block 2000):", feeA);
            assertEq(feeA, 0); // First transaction is clean

            // Transaction B: An immediate bot transaction attempting to extract value inside the SAME block
            swapRouter.swap(
                poolKey,
                IPoolManager.SwapParams({
                    zeroForOne: true,
                    amountSpecified: -1 ether,
                    sqrtPriceLimitX96: SQRT_PRICE_1_1 - 2000
                }),
                Deployers.HookData({testSettings: false, hookData: ZERO_BYTES}),
                ZERO_BYTES
            );
            (, , uint24 feeB, ) = manager.getPoolAndRemainingFee(poolKey);
            console2.log("Transaction B Fee (Second in Block 2000 - MEV Attack!):", feeB);

            // Verify that the hook correctly injected the MEV_PREMIUM_FEE (1.50% = 15000)
            assertEq(feeB, hook.MEV_PREMIUM_FEE());
        }
}
