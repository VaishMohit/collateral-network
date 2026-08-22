// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @title ReentrancyGuard
/// @notice Minimal reentrancy protection.  Uses slot-based storage so that
///         each inheriting contract gets its own independent guard.
abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    error ReentrancyGuard();

    modifier nonReentrant() {
        if (_status == _ENTERED) revert ReentrancyGuard();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    constructor() {
        _status = _NOT_ENTERED;
    }
}
