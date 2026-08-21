# Validation — Phase 1: Critical Correctness Fixes

## Merge criteria

All three must be true before merging to `master`:

1. **All existing tests pass** — `forge test` with zero failures.
2. **New tests pass** — each bug has at least one dedicated test proving the
   fix works.
3. **No regressions** — demo script (`Demo.s.sol`) runs end-to-end on Anvil.

## Test checklist per fix

### Fix 1: AuditRegistry access control

| Test | Expected | File |
|------|----------|------|
| Non-allowed address calls `log()` | reverts | `test/unit/AuditRegistry.t.sol` |
| Allowed address (e.g., CollateralManager) calls `log()` | succeeds | `test/unit/AuditRegistry.t.sol` |
| Admin adds writer, writer calls `log()` | succeeds | `test/unit/AuditRegistry.t.sol` |
| Admin removes writer, writer calls `log()` | reverts | `test/unit/AuditRegistry.t.sol` |
| Non-admin tries to add writer | reverts | `test/unit/AuditRegistry.t.sol` |

### Fix 2: Stale attestation eligibility

| Test | Expected | File |
|------|----------|------|
| Valid attestation → `isEligible()` | true | `test/unit/EligibilityPolicy.t.sol` |
| Expired attestation (vm.warp past expiry) → `isEligible()` | false | `test/unit/EligibilityPolicy.t.sol` |
| Revoked attestation → `isEligible()` | false | `test/unit/EligibilityPolicy.t.sol` |
| Re-attest after expiry → `isEligible()` | true | `test/unit/EligibilityPolicy.t.sol` |

### Fix 3: Single-owner custody

| Test | Expected | File |
|------|----------|------|
| Bank A attests T-BOND, Bank B attests T-BOND | both have independent state | `test/unit/CustodyRegistry.t.sol` |
| Bank A pledges 50 → Bank B available unaffected | Bank B available = 100 | `test/unit/CustodyRegistry.t.sol` |
| `availableQuantity(T_BOND, bankA)` | returns bankA's quantity | `test/unit/CustodyRegistry.t.sol` |
| `availableQuantity(T_BOND, bankB)` | returns bankB's quantity | `test/unit/CustodyRegistry.t.sol` |
| `isAvailableForCollateral(T_BOND, bankA, 100)` | true | `test/unit/CustodyRegistry.t.sol` |
| `isAvailableForCollateral(T_BOND, bankC, 100)` | false (no attestation) | `test/unit/CustodyRegistry.t.sol` |

### Fix 4: Validated flag cleanup

| Test | Expected | File |
|------|----------|------|
| Create, verify, reserve, cancel → re-reserve | requires re-verification | `test/unit/CollateralManager.t.sol` |
| After cancel, `positionApproved()` | false | `test/unit/CollateralManager.t.sol` |

### Fix 5: isCompliant graceful expiry

| Test | Expected | File |
|------|----------|------|
| Valid compliance attestation → `isCompliant()` | true | `test/unit/ComplianceAttestationRegistry.t.sol` |
| Expired attestation → `isCompliant()` | false (no revert) | `test/unit/ComplianceAttestationRegistry.t.sol` |
| Non-existent subject → `isCompliant()` | false (no revert) | `test/unit/ComplianceAttestationRegistry.t.sol` |
| Revoked attestation → `isCompliant()` | false | `test/unit/ComplianceAttestationRegistry.t.sol` |

## Regression checks

| Check | Command | Expected |
|-------|---------|----------|
| Full test suite | `forge test` | 0 failures |
| Demo end-to-end | `forge script script/Demo.s.sol` | completes without revert |
| Gas no regression | `forge test --gas-report` | no significant increase (>10%) on critical paths |

## Definition of done

- [ ] All tests in test checklist pass
- [ ] All regression checks pass
- [ ] No new `require` strings introduced (use custom errors)
- [ ] No new compiler warnings
- [ ] Changes reviewed in diff — each fix is minimal and isolated
