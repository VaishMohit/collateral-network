// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {TestBase} from "../TestBase.sol";
import {ValuationOracle} from "../../src/ValuationOracle.sol";
import {LibConstants as C} from "../../script/LibConstants.sol";

contract ValuationOracleTest is TestBase {
    function setUp() public {
        _deployNetwork();
    }

    function test_providerUpdatesPrice() public {
        _submitPrice(C.T_BOND, 10_000, 1);
        (uint256 price, uint256 timestamp) = oracle.getLatestPrice(C.T_BOND);
        assertEq(price, 10_000);
        assertEq(timestamp, block.timestamp);
    }

    function test_unregisteredProviderReverts() public {
        bytes32 digest = oracle.priceDigest(C.T_BOND, 10_000, block.timestamp, 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(C.PK_BANK_A, digest);
        vm.prank(bankA);
        vm.expectRevert(ValuationOracle.NotAuthorizedProvider.selector);
        oracle.updatePrice(C.T_BOND, 10_000, block.timestamp, v, r, s);
    }

    function test_signatureMustBeFromCaller() public {
        bytes32 digest = oracle.priceDigest(C.T_BOND, 10_000, block.timestamp, 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(C.PK_VALUATION_PROVIDER, digest);
        // Provider's signature, but submitted by someone else.
        vm.prank(mockCsd);
        vm.expectRevert(ValuationOracle.NotAuthorizedProvider.selector);
        oracle.updatePrice(C.T_BOND, 10_000, block.timestamp, v, r, s);
    }

    function test_zeroPriceReverts() public {
        bytes32 digest = oracle.priceDigest(C.T_BOND, 0, block.timestamp, 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(C.PK_VALUATION_PROVIDER, digest);
        vm.prank(valuationProvider);
        vm.expectRevert(ValuationOracle.PriceNotSet.selector);
        oracle.updatePrice(C.T_BOND, 0, block.timestamp, v, r, s);
    }

    function test_futureTimestampReverts() public {
        bytes32 digest = oracle.priceDigest(C.T_BOND, 10_000, block.timestamp + 5 minutes + 1, 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(C.PK_VALUATION_PROVIDER, digest);
        vm.prank(valuationProvider);
        vm.expectRevert(ValuationOracle.PriceInFuture.selector);
        oracle.updatePrice(C.T_BOND, 10_000, block.timestamp + 5 minutes + 1, v, r, s);
    }

    function test_stalePriceReverts() public {
        _submitPrice(C.T_BOND, 10_000, 1);
        vm.warp(block.timestamp + oracle.MAX_PRICE_AGE() + 1);
        vm.expectRevert(ValuationOracle.PriceTooOld.selector);
        oracle.getLatestPrice(C.T_BOND);
    }

    function test_freshPriceAtBoundary() public {
        _submitPrice(C.T_BOND, 10_000, 1);
        vm.warp(block.timestamp + oracle.MAX_PRICE_AGE());
        (uint256 price,) = oracle.getLatestPrice(C.T_BOND);
        assertEq(price, 10_000);
    }

    function test_isPriceFresh() public {
        _submitPrice(C.T_BOND, 10_000, 1);
        assertTrue(oracle.isPriceFresh(C.T_BOND));
        vm.warp(block.timestamp + oracle.MAX_PRICE_AGE() + 1);
        assertFalse(oracle.isPriceFresh(C.T_BOND));
    }

    function test_peekIgnoresStaleness() public {
        _submitPrice(C.T_BOND, 10_000, 1);
        vm.warp(block.timestamp + oracle.MAX_PRICE_AGE() + 1);
        (uint256 price,) = oracle.peekPrice(C.T_BOND);
        assertEq(price, 10_000);
    }

    function test_noPriceReverts() public {
        vm.expectRevert(ValuationOracle.PriceNotSet.selector);
        oracle.getLatestPrice(C.T_BOND);
    }

    function test_noncesMustIncrement() public {
        _submitPrice(C.T_BOND, 10_000, 1);
        _submitPrice(C.T_BOND, 9_800, 2);
        (uint256 price,) = oracle.getLatestPrice(C.T_BOND);
        assertEq(price, 9_800);
        assertEq(oracle.providerNonce(valuationProvider), 2);
    }

    function test_replayedNonceReverts() public {
        _submitPrice(C.T_BOND, 10_000, 1);
        _submitPrice(C.T_BOND, 9_800, 2);
        // Replaying nonce 1 no longer matches the expected nonce (3).
        bytes32 digest = oracle.priceDigest(C.T_BOND, 10_000, block.timestamp, 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(C.PK_VALUATION_PROVIDER, digest);
        vm.prank(valuationProvider);
        vm.expectRevert(ValuationOracle.NotAuthorizedProvider.selector);
        oracle.updatePrice(C.T_BOND, 10_000, block.timestamp, v, r, s);
    }

    function test_perAssetPrices() public {
        _submitPrice(C.T_BOND, 10_000, 1);
        _submitPrice(C.CORP_BOND, 9_500, 2);
        (uint256 tb,) = oracle.getLatestPrice(C.T_BOND);
        (uint256 cb,) = oracle.getLatestPrice(C.CORP_BOND);
        assertEq(tb, 10_000);
        assertEq(cb, 9_500);
    }
}
