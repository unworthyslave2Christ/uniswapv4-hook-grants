// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPermit2} from "../interfaces/IPermit2.sol";

// Copied from
// https://github.com/Uniswap/permit2/blob/cc56ad0f3439c502c246fc5cfcc3db92bb8b7219/src/libraries/PermitHash.sol

library Permit2Hash {
    bytes32 public constant _PERMIT_DETAILS_TYPEHASH = keccak256(
        "PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
    );

    bytes32 public constant _PERMIT_SINGLE_TYPEHASH = keccak256(
        "PermitSingle(PermitDetails details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
    );

    function hashTypedData(address permit2, bytes32 dataHash)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                "\x19\x01", IPermit2(permit2).DOMAIN_SEPARATOR(), dataHash
            )
        );
    }

    function hash(IPermit2.PermitSingle memory permitSingle)
        internal
        pure
        returns (bytes32)
    {
        bytes32 permitHash = _hashPermitDetails(permitSingle.details);
        return keccak256(
            abi.encode(
                _PERMIT_SINGLE_TYPEHASH,
                permitHash,
                permitSingle.spender,
                permitSingle.sigDeadline
            )
        );
    }

    function _hashPermitDetails(IPermit2.PermitDetails memory details)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_PERMIT_DETAILS_TYPEHASH, details));
    }
}
