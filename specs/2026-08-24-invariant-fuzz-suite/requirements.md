# Requirements — Phase 3: Invariant & fuzz test suite

## Context

Phases 1–2 (correctness fixes and hardening) are merged to `master`. The
contracts are now trusted to be correct by construction of their unit tests,
but nothing proves the system holds together under *arbitrary* sequences of
operations. `foundry.toml` already configures `[invariant] runs = 256,
depth = 128, fail_on_revert = true`, and `test/invariants/` exists but is
empty. This phase fills the gap: property-based tests that encode the core
promises of the protocol as executable invariants, plus targeted fuzz tests
for the two most math-heavy entry points, plus gas documentation.

This phase is **local-only** (Anvil semantics, no forks, no L2). Randomized
local state stresses the contracts harder than mainnet data would.

## Scope

Exactly the six steps defined in `specs/roadmap.md` Phase 3:

| Step | Deliverable | Location |
|------|-------------|----------|
| 3.1 | Invariant: collateral accounting `total == reserved + pledged + available` | `test/invariant/AccountingInvariant.t.sol` |
| 3.2 | Invariant: custody encumbrance never exceeds total quantity | `test/invariant/CustodyInvariant.t.sol` |
| 3.3 | Invariant: position status machine — no illegal transitions | `test/invariant/StateMachineInvariant.t.sol` |
| 3.4 | Fuzz: `createPosition` with random quantities, asset IDs, providers | `test/fuzz/CreatePositionFuzz.t.sol` |
| 3.5 | Fuzz: `repayAndClose` with random tenors, rates, amounts | `test/fuzz/RepayCloseFuzz.t.sol` |
| 3.6 | Gas benchmarks for pledge / settlement / substitution / margin / repay | `test/bench/GasBenchmarks.t.sol` + `docs/gas.md` |

### Out of scope

- Leftover TODO.md §1.3 items (attestation-expiry eligibility, multi-owner
  custody, cancelReservation re-validation, AuditRegistry unauthorized
  writes) — assumed covered by Phase 1/2 unit tests; revisit only if an
  invariant run surfaces a gap.
- Any change to `src/**`. This is a test-and-documentation phase. If an
  invariant violation exposes a real bug, it is fixed in a follow-up phase /
  branch with its own spec, not silently patched here.
- Fork testing, Chainlink integration, L2 concerns (later roadmap phases).

## Decisions

1. **Strict six-step scope** (user decision): no expansion into TODO §1.3
   leftovers.
2. **Single shared handler** (user decision): one `BaseHandler` extends
   `TestBase`, deploys the full network once, and exposes weighted actions
   (pledge, release, substitute, default, repo create/settle/repay, price
   updates). All three invariant contracts inherit it. Rationale: less
   duplication, and cross-feature call sequences (e.g., substitute → default
   → release) are exactly where accounting drift hides.
3. **Gas capture: bench test + docs table, no CI gate** (user decision):
   `GasBenchmarks.t.sol` measures critical paths with `gasleft()` deltas;
   numbers are transcribed into `docs/gas.md`. No hard max-gas assertions
   this phase (brittle); a regression gate can be added later.
4. **Handler functions must never revert** — `fail_on_revert = true` means
   every handler action checks its own precondition and returns early
   instead of letting the underlying call revert. Reverts inside the fuzzer
   are failures, not skipped work.
5. **Invariants encode mission principles** (`specs/mission.md`):
   - Principle 1 (state machine integrity) → step 3.3
   - Principle 3 (dual-layer custody, no double-pledging) → step 3.2
   - Accounting identity documented at the top of `CollateralManager`
     (`total tokenized balance == reserved + pledged + available`) → step 3.1

## Success criteria summary

See `validation.md` for the full merge checklist. Short form: `forge test`
green with invariant + fuzz suites active, gas numbers documented in
`docs/gas.md`, zero diffs under `src/`.
