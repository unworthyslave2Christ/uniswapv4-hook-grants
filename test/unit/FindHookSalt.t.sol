// BY GOD'S GRACE  ALONE
// SPDX-License-Identifier: MIT
pragma solidity  ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
// import {console2} from "forge-std/console2.sol";
import {Hooks} from "../../src/libraries/Hooks.sol";
import {HookMiner} from "../../src/libraries/HookMiner.sol";
import {POOL_MANAGER} from "../../src/Constants.sol";
import {DynamicFeeHook} from "../../src/DynamicFeeHook.sol";

/**
 * @title A script to find valid Hooks address
 * @notice Don't run in fork mode, the test may hit the RPC rate limit and return an error
 */

contract FindHookSalt is Test {
    function find(
        address deployer,
        bytes memory code,
        bytes memory args,
        uint160 flags
    ) private view returns (address, bytes32){
        (address addr, bytes32 salt) = HookMiner.find({
            deployer: deployer,
            flags: flags,
            creationCode: code,
            constructorArgs: args
        });

        console.log("Deployer:", deployer);
        console.log("Hook address:", addr);
        console.log("Hook salt:");
        console.logBytes32(salt);

        return(addr, salt);
    }

    function test_dynamic_fee_hook() public {

        (address addr, bytes32 salt) = find(
            address(this),
            type(DynamicFeeHook).creationCode,
            abi.encode(POOL_MANAGER),
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            )
        );

        assertEq(addr, address(new DynamicFeeHook{salt: salt}(POOL_MANAGER)));
    }


}