// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {ProtocolAccessManager} from "./ProtocolAccessManager.sol";
import {Roles} from "./libs/Roles.sol";
import {SignatureVerifier} from "./libs/SignatureVerifier.sol";

/**
 * @title ValuationOracle
 * @notice Signed market-price oracle. Prices come only from an authorized
 *         VALUATION_PROVIDER and every accepted update is authenticated with an
 *         ECDSA signature (assetId, price, timestamp).
 *
 * @dev The contract rejects stale prices: any read of the latest price reverts
 *      once `MAX_PRICE_AGE` has elapsed since the last accepted update. This is
 *      the foundation for mark-to-market collateral valuation.
 */
contract ValuationOracle {
    /// @notice Maximum acceptable age of a price, 5 minutes per spec.
    uint256 public constant MAX_PRICE_AGE = 5 minutes;

    struct PriceData {
        uint256 price; // price in USD cents (e.g. 10000 == $100.00)
        uint256 timestamp;
        address provider;
        uint256 nonce;
    }

    ProtocolAccessManager public immutable access;

    mapping(bytes32 => PriceData) public prices;
    mapping(address => uint256) public providerNonce;

    event PriceUpdated(bytes32 indexed assetId, uint256 price, uint256 timestamp, address indexed provider, uint256 nonce);

    error NotAuthorizedProvider();
    error PriceTooOld();
    error PriceInFuture();
    error PriceNotSet();

    constructor(ProtocolAccessManager access_) {
        access = access_;
    }

    function priceHash(bytes32 assetId, uint256 price, uint256 timestamp, uint256 nonce) public pure returns (bytes32) {
        return keccak256(abi.encode(assetId, price, timestamp, nonce));
    }

    function priceDigest(bytes32 assetId, uint256 price, uint256 timestamp, uint256 nonce) public pure returns (bytes32) {
        return SignatureVerifier.signedDigest(priceHash(assetId, price, timestamp, nonce));
    }

    /**
     * @notice Accept a signed price update. The nonce must be the next unused
     *         nonce for the provider (prevents replay).
     */
    function updatePrice(
        bytes32 assetId,
        uint256 price,
        uint256 timestamp,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        uint256 nonce = providerNonce[msg.sender] + 1;
        address signer = SignatureVerifier.recoverSigner(priceHash(assetId, price, timestamp, nonce), v, r, s);

        // The provider signs with their own key and submits themselves.
        if (signer != msg.sender) revert NotAuthorizedProvider();
        if (!access.hasRole(Roles.VALUATION_PROVIDER, signer)) revert NotAuthorizedProvider();

        if (price == 0) revert PriceNotSet();
        if (timestamp > block.timestamp + 5 minutes) revert PriceInFuture();

        providerNonce[msg.sender] = nonce;
        prices[assetId] = PriceData({price: price, timestamp: timestamp, provider: signer, nonce: nonce});

        emit PriceUpdated(assetId, price, timestamp, signer, nonce);
    }

    /**
     * @notice Returns the latest price, reverting if absent or stale.
     */
    function getLatestPrice(bytes32 assetId) public view returns (uint256 price, uint256 timestamp) {
        PriceData storage p = prices[assetId];
        if (p.price == 0) revert PriceNotSet();
        if (block.timestamp - p.timestamp > MAX_PRICE_AGE) revert PriceTooOld();
        return (p.price, p.timestamp);
    }

    function isPriceFresh(bytes32 assetId) external view returns (bool) {
        PriceData storage p = prices[assetId];
        if (p.price == 0) return false;
        return block.timestamp - p.timestamp <= MAX_PRICE_AGE;
    }

    /// @notice Peek without the staleness check (used by reconciliation).
    function peekPrice(bytes32 assetId) external view returns (uint256 price, uint256 timestamp) {
        PriceData storage p = prices[assetId];
        return (p.price, p.timestamp);
    }
}
