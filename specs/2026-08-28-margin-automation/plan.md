# Phase 4 — Margin Automation: Implementation Plan

Each task group is small enough to complete in a focused session. Groups build
on each other; do not skip ahead. Every group ends compiling and (where
applicable) green before moving on.

## Task Group 1 — On-chain evaluation (contract)

Add read-only evaluation to `MarginManager`.

- [ ] Define `struct MarginEvaluation { bool isAdequate; uint256 shortfall; uint256 requiredValue; uint256 currentValue; }`.
- [ ] `evaluateMargin(bytes32 obligationId) external view returns (MarginEvaluation memory)`:
  - `required = requirements[obligationId]`; if `== 0` revert `NoRequirement()`.
  - `current = collateral.liveCollateralValueForObligation(obligationId)`.
  - Returns `(isAdequate: current >= required, shortfall: required - current, requiredValue, currentValue)`.
  - **Does not revert when adequate.**
- [ ] `previewMarginCall(bytes32 obligationId) external view returns (MarginEvaluation memory)`:
  alias of `evaluateMargin` (documented as a preview that creates nothing).
- [ ] Refactor internal `_evaluateMargin` used by `evaluateMargin` and by
      `createMarginCall`, so the mutating call and the view share one code path.

**Exit:** compiles; unit tests in Group 4 pass for these views.

## Task Group 2 — Batch evaluation + history (contract)

- [ ] `evaluateAll(bytes32[] calldata obligationIds) external onlyBankOrAgent returns (MarginEvaluation[] memory)`:
  - Iterates the supplied obligations; for any shortfall calls the internal
    `_createMarginCall` path (raises a call); returns evaluations for all.
- [ ] `struct MarginCallRecord { bytes32 obligationId; uint256 shortfall; uint256 currentValue; uint256 requiredValue; uint256 timestamp; bool satisfied; bool cancelled; }`.
- [ ] Ring buffer per obligation: `uint256 constant HISTORY_SIZE = 16;`
  `mapping(bytes32 => MarginCallRecord[HISTORY_SIZE]) marginCallHistory;`
  `mapping(bytes32 => uint256) historyHead;` `mapping(bytes32 => uint256) historyCount;`.
- [ ] `_recordMarginCall(obligationId, shortfall, currentValue, requiredValue, satisfied, cancelled)` writes into the ring and emits whether a record was dropped (overflow) — bounds count at 16.
- [ ] Write history from `createMarginCall` path (not satisfied, not cancelled),
      `satisfyMarginCall` (satisfied=true), and `cancelMarginCall` (cancelled=true).
- [ ] `getMarginCallHistory(bytes32) external view returns (MarginCallRecord[] memory)` — newest-first, capped at `HISTORY_SIZE`.
- [ ] `getMarginCallHistoryPaginated(bytes32, uint256 start, uint256 count) external view returns (MarginCallRecord[] memory)`.

**Exit:** compiles; unit tests in Group 4 pass for history and `evaluateAll`.

## Task Group 3 — CLI scaffolding (project)

- [ ] `cli/package.json` (name `margin-monitor`, `"type":"module"`), `tsconfig.json`.
- [ ] Deps: `viem`, `commander`, `chalk`, `dotenv`; dev: `typescript`, `tsx`.
- [ ] `cli/src/config.ts` — read `.env` (`RPC_URL`, `VALUATION_PROVIDER_KEY`,
      `COLLATERAL_AGENT_KEY`), allow per-command `--provider-key`/`--operator-key`.
- [ ] `cli/src/addresses.ts` — load `deployments/anvil.json` into typed contract
      address map; export `walletClient` and `publicClient` (Anvil default
      `http://127.0.0.1:8545`).
- [ ] `cli/src/marginManager.ts` — typed wrappers for `evaluateMargin`,
      `evaluateAll`, `getMarginStatus`, `getMarginCallHistory` via viem.
- [ ] `cli/src/valuationOracle.ts` — typed `updatePrice` (signs as
      VALUATION_PROVIDER with correct monotonic provider nonce).
- [ ] `cli/src/index.ts` — commander command tree with the six commands and `--help`.

**Exit:** `npm run build` passes; `margin-monitor --help` prints all commands.

## Task Group 4 — Contract tests

- [ ] `test/unit/MarginManager.t.sol`: tests for `evaluateMargin` (adequate,
      shortfall, no-requirement revert, stale-price revert), `previewMarginCall`
      (alias equality), `evaluateAll` (creates calls for shortfall only,
      unauthorized reverts, gas), and history (stores create/satisfy, ring
      overwrites at 16, pagination, newest-first).
- [ ] `test/integration/MarginAutomation.t.sol`: full `price drop →
      evaluateAll raises call → satisfy` flow against a deployed network
      (reusing `TestBase`/Deploy helpers and deterministic Anvil keys).

**Exit:** `forge test --match-contract MarginManagerTest` and the new
integration test are green.

## Task Group 5 — CLI commands

- [ ] `price update <asset> <priceCents>` — resolve asset id, read provider
      nonce from oracle, sign with `VALUATION_PROVIDER_KEY`, submit
      `updatePrice`, print new oracle price.
- [ ] `check [obligationId]` — read obligations (single or all tracked), call
      `evaluateMargin`/`evaluateAll` as COLLATERAL_AGENT, print shortfall, and
      raise a call when shortfall > 0.
- [ ] `status <obligationId>` — print `getMarginStatus` (read-only).
- [ ] `history <obligationId>` — print `getMarginCallHistory` (read-only).
- [ ] `watch [--interval ms]` — polling loop: periodically re-evaluate
      (Option A guarantee: only evaluates, never sets price); print when a new
      margin call is raised.
- [ ] `deploy` — run `forge script Deploy` equivalently and write
      `deployments/anvil.json` (or consume the existing Deploy output).

**Exit:** full Option A flow runs on Anvil (see `validation.md`).

## Task Group 6 — Demo update

- [ ] `script/Demo.s.sol`: use `evaluateMargin`/`previewMarginCall`/
      `evaluateAll`/`getMarginCallHistory` where the manual margin-call step
      currently stands; print the evaluation and the raised-call history.
- [ ] Keep the existing lifecycle (pledge → repo → price drop → substitution →
      satisfy) so the demo remains a valid end-to-end walkthrough.

**Exit:** `forge script script/Demo.s.sol` runs clean on Anvil and prints the
automated margin-call evaluation/history.

## Task Group 7 — Validation & merge

- [ ] Run the full `forge test` suite — no regressions.
- [ ] Run the CLI Option A flow against a fresh Anvil node; confirm a price
      drop plus `check` raises a margin call and `status`/`history` reflect it.
- [ ] `forge fmt` and lint clean.
- [ ] Update `validation.md` merge checklist to `done`.
