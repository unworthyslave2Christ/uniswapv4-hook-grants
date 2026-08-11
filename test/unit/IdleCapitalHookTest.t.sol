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
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {SovereignYieldHook} from "../src/SovereignYieldHook.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

// A simple, secure Mock ERC-4626 Vault for local unit testing
contract MockERC4626 is ERC20 {
    IERC20 public immutable asset;

    constructor(IERC20 _asset, string memory name, string memory symbol) ERC20(name, symbol) {
        asset = _asset;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = assets; // 1:1 simplified exchange rate for testing
        asset.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        shares = assets;
        _burn(owner, shares);
        asset.transfer(receiver, assets);
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        return balanceOf(owner);
    }
}

contract SovereignYieldHookTest is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    SovereignYieldHook hook;
    MockERC4626 vault0;
    MockERC4626 vault1;
    PoolKey poolKey;
    PoolId poolId;

    function setUp() public {
        // 1. Initialize the Uniswap V4 core environment
        deployFreshManagerAndRouters();
        deployMintAndApprove2Tokens();

        // 2. Deploy our Mock ERC-4626 Vaults mapping to Token0 and Token1
        vault0 = new MockERC4626(IERC20(Currency.unwrap(currency0)), "Yield Token 0", "yTK0");
        vault1 = new MockERC4626(IERC20(Currency.unwrap(currency1)), "Yield Token 1", "yTK1");

        // 3. Setup the exact address flags required for Hook #3
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
        );

        // 4. Mine deployment salt and pass Manager address
        bytes memory constructorArgs = abi.encode(manager);
        address hookAddress = deployCodeToAddress(
            "SovereignYieldHook.sol:SovereignYieldHook",
            constructorArgs,
            flags
        );
        hook = SovereignYieldHook(hookAddress);

        // 5. Pack Vault address configs into hookData for the initialization frame
        bytes memory hookData = abi.encode(address(vault0), address(vault1));

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000, // 0.30% baseline fee
            tickSpacing: 60,
            hook: hook
        });
        poolId = poolKey.toId();

        // 6. Initialize the pool passing our hook structural configuration data
        manager.initialize(poolKey, SQRT_PRICE_1_1, hookData);
    }
    function test_liquidity_provision_sweeps_to_yield_vault() public {
        console2.log("--- SIMULATING LIQUIDITY DEPOSIT AND ASSET SWEEP ---");

        uint256 poolReserveBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(manager));
        uint256 vaultBalanceBefore = vault0.balanceOf(address(hook));

        // 1. Add 100 Ether of concentrated liquidity into the pool manager
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        uint256 poolReserveAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(manager));
        uint256 vaultBalanceAfter = vault0.balanceOf(address(hook));

        console2.log("Tokens left idle inside Pool Manager:", poolReserveAfter - poolReserveBefore);
        console2.log("Tokens swept to ERC-4626 Vault:", vaultBalanceAfter - vaultBalanceBefore);

        // Assert that exactly 90% of deposited tokens went straight to the yield vault
        // leaving a 10% gas buffer inside the pool manager contract
        assertEq(vaultBalanceAfter, (100 ether * 90) / 100);
    }

    function test_large_swap_triggers_emergency_vault_recall() public {
        console2.log("--- SIMULATING INSTANT LIQUIDITY RECALL ON HUGE SWAP ---");

        // 1. Seed initial base liquidity
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 50 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        // Ensure the vault successfully captured capital assets
        uint256 vaultSharesLocked = vault1.balanceOf(address(hook));
        assertTrue(vaultSharesLocked > 0);
        console2.log("Vault Yield Assets before Swap spike:", vaultSharesLocked);

        // 2. Force an aggressive swap that requires more liquidity than what is floating loose
        // This will activate our hook's `beforeSwap` deficit check
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -10 ether, // High volume trade parameters
                sqrtPriceLimitX96: SQRT_PRICE_1_1 - 10000
            }),
            Deployers.HookData({testSettings: false, hookData: ZERO_BYTES}),
            ZERO_BYTES
        );

        uint256 vaultSharesAfterSwap = vault1.balanceOf(address(hook));
        console2.log("Vault Yield Assets after Swap recall:", vaultSharesAfterSwap);
        
        // Confirm the hook programmatically pulled funds out of the vault to fulfill the swap
        assertTrue(vaultSharesAfterSwap < vaultSharesLocked);
    }
}
