# Phase 4 — Margin Automation: Requirements

Date: 2026-08-28
Branch: `phase-4-margin-automation`

## Context

The Collateral Network tracks collateral requirements (obligations) and
generates / satisfies margin calls in `MarginManager`. Today margin calls are
raised **manually** via `createMarginCall(obligationId)` by a BANK or
COLLATERAL_AGENT, and there is no on-chain record of past calls, no
non-mutating evaluation, and no batch evaluation.

Phase 4 makes margin calls **automated** in a two-actor model that mirrors the
institutional / DeFi analogue:

- **Data provider** (VALUATION_PROVIDER) submits fresh signed prices into
  `ValuationOracle` — analogous to a Chainlink feed, or a tri-party agent
  delivering a collateral valuation.
- **Operator** (COLLATERAL_AGENT) evaluates obligations against those prices and
  raises margin calls — analogous to Chainlink Automation (a keeper) or a
  DTCC-style margin-desk UI pressing "run margin call".

This is driven end-to-end by a **CLI** (`margin-monitor`) on a local Anvil
devnet. The contract surface is designed so the operator side can later be
replaced by an on-chain Chainlink keeper without changing the contracts
(see roadmap Phase 11).

## Scope

### In scope

1. On-chain `MarginManager` additions:
   - `MarginEvaluation` struct + `evaluateMargin(obligationId)` view.
   - `previewMarginCall(obligationId)` view.
   - `evaluateAll(obligationIds[])` — raises a margin call for any obligation
     with a shortfall; gated by `onlyBankOrAgent`.
   - Bounded margin-call history (ring buffer of last 16) per obligation, with
     `getMarginCallHistory` and a paginated view; written by
     create/satisfy/cancel.
2. `margin-monitor` CLI (TypeScript + viem + commander + chalk):
   - `deploy`, `price update`, `check`, `watch`, `status`, `history`.
   - Two distinct signer keys: VALUATION_PROVIDER (`price update`),
     COLLATERAL_AGENT (`check`/`watch`). `status`/`history` read-only.
3. Tests: unit + integration covering the price-drop → margin-call workflow.
4. Demo update: use `evaluateMargin`/`evaluateAll`/history.

### Out of scope (for this implementation)

- Production Chainlink price feeds (roadmap Phase 9).
- On-chain Chainlink keeper (`MarginKeeper`, roadmap Phase 11).
- Live tri-party agent integration.
- Cross-chain, multi-currency, SDK (later phases).

## Key decisions

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | `evaluateMargin` returns a `MarginEvaluation` struct `(shortfall, currentValue, requiredValue, isAdequate)`; does **not** revert when adequate | Needed by `check` to distinguish "no shortfall" from an error |
| D2 | `evaluateAll(obligationIds[])` takes an explicit obligation-ids array | Caller (operator) controls gas and scope |
| D3 | History ring buffer fixed at 16 per obligation | Bounded on-chain storage |
| D4 | CLI automation is **Option A (edge-triggered, two commands)**: `price update` and `check` are separate commands; a price update does **not** auto-trigger evaluation | Keeps data-provider and operator separate; nothing on-chain links them |
| D5 | Operator signs calls as COLLATERAL_AGENT (not a new role) | Matches existing `onlyBankOrAgent` and the tri-party framing; a dedicated keeper role deferred to Phase 11 |
| D6 | CLI stack = TypeScript + viem + commander + chalk | Reusable toward the Phase 14 SDK; viem for Anvil interaction |

## Actors & keys (CLI)

| Role | Anvil key (`script/LibConstants.sol`) | CLI command | On-chain call |
|------|----------------------------------------|-------------|---------------|
| VALUATION_PROVIDER | `PK_VALUATION_PROVIDER` | `price update` | `ValuationOracle.updatePrice` |
| COLLATERAL_AGENT | `PK_COLLATERAL_AGENT` | `check`, `watch` | `MarginManager.evaluate*` |
| — (read-only) | none | `status`, `history` | `MarginManager.get*` views |

Keys from `.env` (`VALUATION_PROVIDER_KEY`, `COLLATERAL_AGENT_KEY`), overridable
per command. See `specs/phase4-cli.md` for the full command reference.
