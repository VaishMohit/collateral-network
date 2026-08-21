# Plan — Phase 1: Critical Correctness Fixes

## Task Group 1: AuditRegistry access control

**Files:** `src/AuditRegistry.sol`, `test/unit/AuditRegistry.t.sol`

1. Add a `mapping(address => bool) public allowedWriters` and an `allowWriter`
   / `disallowWriter` admin function to AuditRegistry.
2. Add `modifier onlyAllowedWriter()` that checks `allowedWriters[msg.sender]`.
3. Add `modifier onlyAdmin()` that checks `access.hasRole(ADMIN, msg.sender)`.
4. Gate `log()` with `onlyAllowedWriter`.
5. In `Deploy.s.sol`, after deploying AuditRegistry and the workflow contracts,
   call `audit.allowWriter()` for each: CollateralManager, PledgeManager,
   MarginManager, SettlementCoordinator, RepoManager, and AuditRegistry itself
   (if self-logging).
6. Write test: non-allowed address calling `log()` reverts.
7. Write test: allowed address calling `log()` succeeds.
8. Write test: admin can add/remove writers.

## Task Group 2: Stale attestation eligibility bypass

**Files:** `src/EligibilityPolicy.sol`, `test/unit/EligibilityPolicy.t.sol`

1. In `EligibilityPolicy.isEligible()`, after reading `cs.lastAttestationId`,
   call `attestationRegistry.verifyAttestation(cs.lastAttestationId)` to
   confirm the attestation is still valid.
2. `verifyAttestation` already reverts if the attestation is invalid, so the
   eligibility check will fail if the attestation has expired or been revoked.
3. Write test: attest asset, wait past expiry (vm.warp), verify eligibility
   returns false.
4. Write test: attest asset, revoke attestation, verify eligibility returns
   false.
5. Write test: attest asset, attestation still valid, verify eligibility
   returns true (regression).

## Task Group 3: Single-owner-per-asset custody

**Files:** `src/CustodyRegistry.sol`, `src/CollateralManager.sol`,
`src/EligibilityPolicy.sol`, `test/unit/CustodyRegistry.t.sol`

1. Change `custodyStates` mapping key from `bytes32` (assetId) to
   `bytes32` (keccak256 of assetId + owner).
2. Add internal helper `_custodyKey(bytes32 assetId, address owner)` that
   computes the key.
3. Update `updateCustodyAttestation`: use `_custodyKey(a.assetId, a.owner)`.
4. Update `applyEncumbrance`: add `address owner` parameter, use
   `_custodyKey(assetId, owner)`.
5. Update `getCustodyState`: add `address owner` parameter.
6. Update `availableQuantity`: add `address owner` parameter.
7. Update `isAvailableForCollateral`: already takes owner, update internal key.
8. Update `CollateralManager._lock`, `_unlock`, `_release`,
   `availableQuantity`: pass provider address to custody registry calls.
9. Update `EligibilityPolicy.isEligible`: pass `owner` to custody registry
   calls.
10. Write test: two banks hold same ISIN, each has independent custody state.
11. Write test: encumbrance for one owner does not affect the other.
12. Write test: available quantity is per-owner, not global.

## Task Group 4: Clear validated flag on cancel

**Files:** `src/CollateralManager.sol`, `test/unit/CollateralManager.t.sol`

1. In `cancelReservation()`, add `delete validated[positionId]` after setting
   status back to AVAILABLE.
2. Write test: create position, verify, reserve, cancel, verify that
   `positionApproved` returns false and re-reservation requires re-validation.
3. Write test: cancelReservation emits event (existing test, regression).

## Task Group 5: isCompliant graceful expiry

**Files:** `src/ComplianceAttestationRegistry.sol`,
`test/unit/ComplianceAttestationRegistry.t.sol`

1. In `isCompliant()`, replace `require(attestation.expiry > block.timestamp,
   "expired")` with an if-statement: `if (attestation.expiry <=
   block.timestamp) return false;`.
2. Write test: compliant attestation, warp past expiry, call `isCompliant`,
   assert returns false (not reverts).
3. Write test: compliant attestation within window, `isCompliant` returns true
   (regression).
4. Write test: non-existent subject, `isCompliant` returns false (regression).

## Execution order

Tasks 1-5 are independent and can be done in parallel. However, Task 3
(single-owner) changes the CustodyRegistry interface and affects Tasks 1
(AuditRegistry uses roles, not custody) and 2 (EligibilityPolicy calls
custody). Task 2 depends on the new custody key signature from Task 3.

Recommended order:
1. Task Group 4 (trivial, no dependencies)
2. Task Group 5 (trivial, no dependencies)
3. Task Group 1 (self-contained)
4. Task Group 3 (interface change)
5. Task Group 2 (depends on Task 3's interface)
