// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/**
 * @title SignatureVerifier
 * @notice Minimal ECDSA helpers (no external dependencies) used by the
 *         attestation services. Produces/verifies ERC-191 personal-sign style
 *         digests so off-chain signers (the Mock CSD, Custodian, price provider,
 *         compliance provider) can produce signatures with standard wallets.
 */
library SignatureVerifier {
    /// @notice Wraps a struct hash in the Ethereum signed-message envelope.
    function toEthSignedMessageHash(bytes32 hash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }

    /// @notice Recovers the signer of `hash` given the ECDSA signature components.
    function recoverSigner(bytes32 hash, uint8 v, bytes32 r, bytes32 s) internal pure returns (address) {
        bytes32 digest = toEthSignedMessageHash(hash);
        address signer = ecrecover(digest, v, r, s);
        require(signer != address(0), "Sig: invalid signature");
        return signer;
    }

    /// @notice Returns the exact digest an off-chain signer must sign.
    function signedDigest(bytes32 hash) internal pure returns (bytes32) {
        return toEthSignedMessageHash(hash);
    }
}
