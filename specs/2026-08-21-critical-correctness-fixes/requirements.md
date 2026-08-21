# Requirements — Phase 1: Critical Correctness Fixes

## Context

The V1 collateral network has five correctness issues that compromise system
integrity. These must be fixed before any new features. The approach is
minimal — each fix is the smallest possible change that resolves the bug
without refactoring surrounding code.

## Scope

All five bugs from `specs/roadmap.md` Phase 1.

### Bug 1: AuditRegistry has no access control

**File:** `src/AuditRegistry.sol`
**Problem:** The `log()` function is `external` with no modifier. Any address
can write fake audit records, polluting the audit trail.
**Fix:** Gate `log()` to registered operator contracts. The AuditRegistry
already receives `access` (ProtocolAccessManager) in its constructor. Check
that `msg.sender` has a recognized role (BANK, CSD, CUSTODIAN,
COLLATERAL_AGENT, VALUATION_PROVIDER, SETTLEMENT_AGENT, COMPLIANCE_PROVIDER)
or is a known contract (CollateralManager, PledgeManager, etc.).

**Decision:** Use a whitelist approach — store allowed writers in a mapping
set by admin, rather than checking every role. This avoids coupling to the
role constants and allows new contracts to be added without modifying
AuditRegistry.

### Bug 2: Stale attestation eligibility bypass

**Files:** `src/EligibilityPolicy.sol`, `src/CustodyRegistry.sol`
**Problem:** After `updateCustodyAttestation`, if the attestation is later
revoked or expires, `EligibilityPolicy.isEligible()` still passes because it
only checks `lastAttestationId != bytes32(0)`, not whether the attestation
is currently valid.
**Fix:** In `isEligible()`, after reading `cs.lastAttestationId`, call
`attestationRegistry.verifyAttestation(cs.lastAttestationId)` to confirm the
attestation is still valid (exists, not revoked, not expired).

**Decision:** This adds a cross-contract call in the eligibility check.
Acceptable because `isEligible` is a view function called during verification,
not in hot paths. If gas becomes a concern, cache validity on attestation
submission.

### Bug 3: Single-owner-per-asset limitation

**Files:** `src/CustodyRegistry.sol`, `src/CollateralManager.sol`
**Problem:** `CustodyRegistry` maps `assetId => CustodyState`. Two banks
holding the same ISIN would overwrite each other's custody state.
**Fix:** Change the mapping key from `bytes32` (assetId) to `bytes32` derived
from `keccak256(abi.encode(assetId, owner))`. Update all read/write paths:
`updateCustodyAttestation`, `applyEncumbrance`, `getCustodyState`,
`availableQuantity`, `isAvailableForCollateral`.

**Decision:** The `availableQuantity` function currently takes only `assetId`.
After this fix it must also take `owner`. This changes the external interface
of CustodyRegistry. All callers (EligibilityPolicy, CollateralManager) must
be updated.

### Bug 4: `cancelReservation` does not clear `validated` flag

**File:** `src/CollateralManager.sol`
**Problem:** When `cancelReservation()` is called, the position goes back to
AVAILABLE but `validated[positionId]` remains true. A subsequent
`reserveCollateral()` would skip re-validation.
**Fix:** Add `delete validated[positionId]` in `cancelReservation()`.

**Decision:** Minimal one-line change. No interface changes needed.

### Bug 5: `isCompliant` reverts on expired attestation

**File:** `src/ComplianceAttestationRegistry.sol`
**Problem:** `isCompliant()` reverts when the attestation is expired instead
of returning `false`. This breaks composability — any view function calling
`isCompliant` would also revert.
**Fix:** Wrap the expiry check in a try/catch or restructure the logic to
return `false` when expired instead of reverting.

**Decision:** Change `require(attestation.expiry > block.timestamp)` to an
if-statement that returns `false`. The function already returns `bool`.

## Out of scope

- Reentrancy guards (Phase 2)
- Gas-limit protection on `positionsByObligation` (Phase 2)
- Inconsistent error style (Phase 2)
- Missing events (Phase 2)
- `PledgeManager.approveRelease` counter-party logic (Phase 2)

## References

- `specs/mission.md` — principle 1 (state machine integrity), principle 3
  (dual-layer custody)
- `specs/tech-stack.md` — ProtocolAccessManager for role checks
- `TODO.md` — Phase 1 items 1.1 through 1.5
