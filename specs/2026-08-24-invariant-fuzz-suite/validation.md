# Validation — Phase 3: Invariant & fuzz test suite

## Merge criteria

All must be true before merging to `master`:

1. **Full suite green** — `forge test` passes with zero failures, including
   the new invariant and fuzz contracts.
2. **Invariants survive full runs** — `forge test --match-contract
   "Invariant"` completes 256 runs × depth 128 with no violation and no
   revert-failure (the `fail_on_revert = true` setting stays enabled; it may
   not be weakened to make tests pass).
3. **No source changes** — `git diff master --stat -- src/` is empty. Any
   bug discovered by this suite is deferred to a follow-up fix branch with
   its own spec (see requirements.md, Out of scope).
4. **No weakening of existing tests** — `git diff master -- test/unit/
   test/integration/` only contains additions required by handler reuse,
   never deletions or assertion loosening.
5. **Demo still works** — `forge script script/Demo.s.sol` runs end-to-end
   on Anvil.
6. **Gas documented** — `docs/gas.md` exists with measured numbers for all
   five benchmarked paths and a date stamp.

## Per-step checklist

### Step 3.1: Accounting invariant

| Check | Expected |
|-------|----------|
| `invariant_TotalEqualsBreakdown()` after random pledge/release/substitute/default sequences | holds for all runs |
| Ghost per-position record vs on-chain position | exact match on quantity + status |
| Settled repo cash flow: receiver debit vs provider credit | equal to wei |

### Step 3.2: Custody invariant

| Check | Expected |
|-------|----------|
| `encumberedQuantity <= totalQuantity` for every touched `(assetId, owner)` | never violated |
| `availableQuantity()` == `total - encumbered` for those keys | exact match |
| Two banks attesting the same ISIN under random interleavings | independent state preserved |

### Step 3.3: State machine invariant

| Check | Expected |
|-------|----------|
| Every observed transition ∈ legal edge set | always |
| Position in RELEASED / RECOVERY changes status again | impossible |

### Step 3.4: Fuzz createPosition

| Check | Expected |
|-------|----------|
| Valid random inputs → position created, custody incremented by exactly `quantity` | always |
| Zero quantity / unregistered asset / unattested provider | specific custom errors, not generic reverts |
| Full-amount pledge drains available to zero | subsequent pledge of same asset+owner reverts with InsufficientAvailable |

### Step 3.5: Fuzz repayAndClose

| Check | Expected |
|-------|----------|
| Returned `repaid` == principal + interest under RepoManager's day-count convention | exact match across all fuzz inputs |
| Max-rate × max-tenor probe | no overflow, no truncation |
| Repay before settle / double repay / non-party / post-default | specific custom errors |

### Step 3.6: Gas benchmarks

| Check | Expected |
|-------|----------|
| Benchmarks run deterministically (`forge test --match-contract GasBench`) | pass, log values |
| `docs/gas.md` table covers pledge, settlement, substitution, margin call, repay | present, dated |

## Known limitations accepted at merge

- Invariants are only as complete as the handler's action set; unmodeled
  entry points are not covered. Handler extensions belong to later phases.
- Gas numbers are machine-dependent (documented as such in `docs/gas.md`);
  they are a reference, not a regression gate.
