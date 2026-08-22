# Phase 2 — Correctness Hardening

## 2.1 Reentrancy guards

**What:** Add `nonReentrant` to all external functions that perform external calls (token transfers, external contract calls).

**Why:** Defense-in-depth. Even though CashToken and TokenizedSecurity are trusted in-repo tokens, future upgrades or integrations could introduce hooks. Protecting at the state-machine level prevents reentrancy regardless of callee behavior.

**Files:**
- `src/libs/ReentrancyGuard.sol` — minimal slot-based guard (new)
- `src/CollateralManager.sol` — `reserveCollateral`, `cancelReservation`, `enforceCollateral`, `reserveReplacement`, `activateSubstitution`
- `src/RepoManager.sol` — `repayAndClose`
- `src/SettlementCoordinator.sol` — `settleRepo`

## 2.2 Obligation position cap

**What:** Cap `positionsByObligation` at 64 entries. Add paginated view.

**Why:** Unbounded storage arrays are a gas griefing vector. A malicious or buggy caller could push unlimited positions into a single obligation, making `getPositionsByObligation` and iteration loops ungasable. 64 is generous for real-world obligations.

**Files:**
- `src/CollateralManager.sol` — `MAX_OBLIGATION_POSITIONS = 64`, checks in `createPosition`, `createReplacementPosition`, `linkObligation`, new `getPositionsByObligationPaginated` view

## 2.3 Custom errors everywhere

**What:** Replace all `require(cond, "string")` with custom errors.

**Why:** Custom errors are gas-efficient, tooling-friendly, and type-safe. String reverts are 2-3x more expensive and can't be pattern-matched by off-chain code.

**Files:** All `src/*.sol` — 29 string requires replaced across 11 contracts

## 2.4 Missing events

**What:** Add `ReservationCancelled`, `PositionApproved`, `PositionDefaulted` events to CollateralManager.

**Why:** Off-chain indexers and monitoring need to track all state transitions. Silent transitions are invisible to dashboards and alerting.

**Files:**
- `src/CollateralManager.sol` — 3 new events emitted in `cancelReservation`, `markApproved`, `markDefault`

## 2.5 PledgeManager release counter-party enforcement

**What:** Track who requested release; only the counter-party may approve.

**Why:** The original code allowed either party to approve release without checking who requested it. This defeats the purpose of bilateral consent. Agent can always approve.

**Files:**
- `src/PledgeManager.sol` — `releaseRequestor` mapping, `requestRelease` records requestor, `approveRelease` enforces counter-party
