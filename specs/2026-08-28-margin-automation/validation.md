# Phase 4 — Margin Automation: Validation

How we know the implementation succeeded and can be merged.

## Contract tests (F1–Fn)

| ID | Check |
|----|-------|
| F1 | `evaluateMargin` returns `isAdequate=true`, `shortfall=0` when collateral value ≥ requirement (no revert). |
| F2 | `evaluateMargin` returns `isAdequate=false`, correct `shortfall=required-current` on a price drop. |
| F3 | `evaluateMargin` reverts `NoRequirement` when no requirement is set. |
| F4 | `evaluateMargin` reverts on a stale price (warp past `MAX_PRICE_AGE`). |
| F5 | `previewMarginCall` returns identical values to `evaluateMargin` and mutates nothing. |
| F6 | `evaluateAll([ids])` raises a margin call only for obligations with a shortfall. |
| F7 | `evaluateAll` reverts `Unauthorized` when called by a non-BANK/non-AGENT. |
| F8 | `evaluateAll` returns an evaluation per input obligation in matching order. |
| F9 | History stores a record on `createMarginCall` (satisfied=false). |
| F10 | History stores a record on `satisfyMarginCall` (satisfied=true). |
| F11 | History stores a record on `cancelMarginCall` (cancelled=true). |
| F12 | `getMarginCallHistory` returns records newest-first, capped at `HISTORY_SIZE` (16). |
| F13 | Ring buffer overwrites: >16 records still yield a history of length 16. |
| F14 | `getMarginCallHistoryPaginated` returns the correct slice and empty beyond the end. |

## Integration test (I)

| ID | Check |
|----|-------|
| I1 | Deployed network: pledged obligation with a requirement; a fresh price drop then `evaluateAll` (as COLLATERAL_AGENT) raises an active `MarginCall` with shortfall > 0. |
| I2 | After posting additional collateral and `satisfyMarginCall`, the call is satisfied and history reflects create + satisfy. |

## CLI validation (C1–C9) — on a fresh Anvil node (`deployments/anvil.json`)

| ID | Command | Expected |
|----|---------|----------|
| C1 | `margin-monitor price update T_BOND 10000` | Price pushed; oracle returns $100.00. No call raised. |
| C2 | `margin-monitor check 0x<obligationId>` | Reports adequate; no active call. |
| C3 | `margin-monitor price update T_BOND 9200` | Price falls to $92.00. |
| C4 | `margin-monitor check 0x<obligationId>` | Raises an active margin call; shortfall = $26,000. |
| C5 | `margin-monitor status 0x<obligationId>` | Shows active call, `currentValue` < `requiredValue`. |
| C6 | `margin-monitor history 0x<obligationId>` | Contains the raised-call record. |
| C7 | `margin-monitor check` (no arg) | Evaluates all tracked obligations; raises calls for shortfall only. |
| C8 | `margin-monitor watch` | Auto-raises the call once price crosses the threshold, without a manual `check`. |
| C9 | `price update` alone never raises a call (Option A). | Confirmed by C1/C3 + C4 needing an explicit `check`. |

Key requirement: `VALUATION_PROVIDER_KEY` signs `price update`;
`COLLATERAL_AGENT_KEY` signs `check`/`watch`.

## Demo (D1)

| ID | Check |
|----|-------|
| D1 | `forge script script/Demo.s.sol` runs on Anvil and prints the automated margin evaluation, the raised-call history, and the existing full lifecycle (pledge → repo → price drop → substitution → satisfy). |

## Non-functional (NF)

| ID | Check |
|----|-------|
| NF1 | History storage is bounded — no unbounded array growth per obligation. |
| NF2 | `evaluateAll` caller controls gas scope via the supplied obligation-ids array. |
| NF3 | `price update` and `evaluate*` remain separate on-chain calls (two-actor separation; Option A). |
| NF4 | Full `forge test` suite passes — no regressions. |
| NF5 | `forge fmt` / lint clean. |
| NF6 | CLI builds (`npm run build`) and `--help` lists all commands. |

## Merge checklist

- [ ] All F1–F14 green.
- [ ] I1–I2 green.
- [ ] C1–C9 verified on a fresh Anvil node.
- [ ] D1 demo runs and prints evaluation/history.
- [ ] NF1–NF6 satisfied.
- [ ] Branch `phase-4-margin-automation` up to date with `master`; spec +
      implementation committed; merge requested.
