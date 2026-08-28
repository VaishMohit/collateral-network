# Roadmap

Each phase is small enough to complete in a focused work session. Phases
build on each other — do not skip ahead. Every phase ends with passing
tests and a working demo on Anvil.

---

## Phase 1 — Fix critical correctness bugs

**Goal:** The five correctness issues that compromise system integrity are
resolved.

| Step | Task | Files |
|------|------|-------|
| 1.1 | Gate `AuditRegistry.log()` to registered operator contracts only | `src/AuditRegistry.sol`, `test/unit/AuditRegistry.t.sol` |
| 1.2 | Verify attestation validity in `EligibilityPolicy.isEligible()` — check the attestation has not expired or been revoked | `src/EligibilityPolicy.sol`, `test/unit/EligibilityPolicy.t.sol` |
| 1.3 | Key `CustodyRegistry` on `(assetId, owner)` instead of `assetId` alone | `src/CustodyRegistry.sol`, `src/CollateralManager.sol`, `test/unit/CustodyRegistry.t.sol` |
| 1.4 | Clear `validated[positionId]` in `CollateralManager.cancelReservation()` | `src/CollateralManager.sol`, `test/unit/CollateralManager.t.sol` |
| 1.5 | Make `ComplianceAttestationRegistry.isCompliant()` return `false` instead of reverting on expired attestation | `src/ComplianceAttestationRegistry.sol`, `test/unit/ComplianceAttestationRegistry.t.sol` |

**Exit:** All existing tests pass. New tests cover each fix.

---

## Phase 2 — Correctness hardening

**Goal:** Edge cases and safety properties are addressed.

| Step | Task | Files |
|------|------|-------|
| 2.1 | Add `nonReentrant` to `_lock` / `_release` / `enforceCollateral` paths | `src/CollateralManager.sol` |
| 2.2 | Cap `positionsByObligation` at a maximum (e.g., 64) and add paginated view | `src/CollateralManager.sol` |
| 2.3 | Standardize all error handling to custom errors (remove `require` strings) | All `src/*.sol` |
| 2.4 | Add missing events: `ReservationCancelled`, `PositionApproved`, `PositionDefaulted` | `src/CollateralManager.sol` |
| 2.5 | Fix `PledgeManager.approveRelease` to enforce counter-party logic or correct the comment | `src/PledgeManager.sol` |

**Exit:** All existing tests pass. New tests for reentrancy, cap, and events.

---

## Phase 3 — Invariant & fuzz test suite

**Goal:** Property-based tests prove the core invariants hold under
randomized inputs.

| Step | Task | Files |
|------|------|-------|
| 3.1 | Invariant: collateral accounting `total == reserved + pledged + available` | `test/invariant/Accounting.t.sol` |
| 3.2 | Invariant: custody encumbrance never exceeds total quantity | `test/invariant/Custody.t.sol` |
| 3.3 | Invariant: position status machine transitions (no invalid jumps) | `test/invariant/StateMachine.t.sol` |
| 3.4 | Fuzz: `createPosition` with random quantities, asset IDs, providers | `test/fuzz/` |
| 3.5 | Fuzz: `repayAndClose` with random tenors, rates, amounts | `test/fuzz/` |
| 3.6 | Gas benchmark: measure gas for pledge, settlement, substitution, margin call | `test/bench/GasBenchmarks.t.sol` |

**Exit:** `forge test` passes with invariant and fuzz tests. Gas numbers documented.

---

## Phase 4 — Margin automation

**Goal:** Margin calls happen automatically when prices change, driven by a
CLI/UI operator — mirroring how a Chainlink feed pushes prices and a Chainlink
keeper (or a DTCC-style margin-desk UI) raises the call. Two actors stay
separate:

- **Data provider** = `VALUATION_PROVIDER`, submits signed prices (analogous to
  Chainlink pushing a feed, or a tri-party agent delivering a collateral
  valuation). In the CLI this is `margin-monitor price update <asset> <price>`,
  which **only** pushes a price into the oracle — it never evaluates or raises
  a call.
- **Operator** = `COLLATERAL_AGENT`, evaluates obligations and raises calls
  (analogous to Chainlink Automation / a margin-desk UI pressing "run margin
  call"). In the CLI this is `margin-monitor check` (one evaluation) or `watch`
  (continuous polling). It consumes the price but never sets it.

**Edge-triggered, two commands (Option A).** A single `price update` does **not**
auto-trigger evaluation: `price update` and `check` are separate commands from
separate contract calls (`ValuationOracle.updatePrice` vs
`MarginManager.evaluateAll`), and nothing on-chain links them. The operator
explicitly runs `check` after the price moves. A later `watch` loop automates
repeatedly running `check`.

The on-chain `MarginManager` gains read-only evaluation (`evaluateMargin`,
`previewMarginCall`), batch evaluation (`evaluateAll`), and bounded margin-call
history. The CLI exercises the full workflow on an Anvil devnet and can
later have its operator side swapped for an on-chain Chainlink keeper without
changing the contract surface.

**CLI keys required.** Two distinct signer keys, one per role:

| Role | Anvil key (`script/LibConstants.sol`) | CLI command |
|------|----------------------------------------|-------------|
| VALUATION_PROVIDER | `PK_VALUATION_PROVIDER` | `price update` |
| COLLATERAL_AGENT | `PK_COLLATERAL_AGENT` | `check`, `watch` |

`status` / `history` are read-only (no key). Keys come from `.env`
(`VALUATION_PROVIDER_KEY`, `COLLATERAL_AGENT_KEY`), overridable per command.

| Step | Task | Files |
|------|------|-------|
| 4.1 | `MarginEvaluation` struct view `evaluateMargin(obligationId)` — returns `(shortfall, currentValue, requiredValue, isAdequate)`; does **not** revert when adequate (needed by `check`) | `src/MarginManager.sol` |
| 4.2 | `previewMarginCall(obligationId)` — non-mutating preview of what a call would raise | `src/MarginManager.sol` |
| 4.3 | `evaluateAll(obligationIds[])` — iterate obligations, create a margin call for any with shortfall (caller = operator/agent controls gas) | `src/MarginManager.sol` |
| 4.4 | Bounded margin-call history per obligation (ring buffer of last 16) with `getMarginCallHistory` / paginated view; written by create/satisfy/cancel | `src/MarginManager.sol` |
| 4.5 | CLI `margin-monitor` project (TypeScript + viem + commander): `deploy`, `price update`, `check`, `watch`, `status`, `history` | `cli/` |
| 4.6 | CLI `price update` signs as VALUATION_PROVIDER; `check`/`watch` invoke `evaluateAll`/`evaluateMargin` as COLLATERAL_AGENT; read deployment from `deployments/anvil.json` | `cli/src/` |
| 4.7 | `watch` mode — polling loop that refreshes prices and evaluates, standing in for Chainlink Automation / a continuously-running margin desk | `cli/src/` |
| 4.8 | CLI command + key semantics documented (Option A: `price update` then separate `check`), two roles, `.env` keys | `specs/phase4-cli.md` |
| 4.9 | Tests: evaluateMargin, evaluateAll, preview, ring-buffer history, price-update + call workflow | `test/unit/MarginManager.t.sol`, `test/integration/MarginAutomation.t.sol` |
| 4.10 | Demo update: use `evaluateMargin`/`evaluateAll`/history; show price drop → operator raises call → system asks for more collateral | `script/Demo.s.sol` |

**Exit:** `forge test` passes. `margin-monitor` CLI on Anvil updates a price and
raises a margin call end-to-end, and `watch` demonstrates automated monitoring.
The operator side is structured so a Chainlink keeper can replace it in a later
phase.

---

## Phase 5 — Repo enhancements

**Goal:** Repos support early repayment, grace periods, and rollover.

| Step | Task | Files |
|------|------|-------|
| 5.1 | Early repayment with pro-rata interest (ACT/360 day-count) | `src/RepoManager.sol` |
| 5.2 | Configurable grace period before default can be triggered | `src/RepoManager.sol` |
| 5.3 | Late repayment penalty — additional interest accrual after maturity | `src/RepoManager.sol` |
| 5.4 | Repo rollover — close expiring repo and open new one atomically | `src/RepoManager.sol` |
| 5.5 | Tests: early repay, grace period, penalty, rollover | `test/unit/RepoManager.t.sol` |

**Exit:** `forge test` passes. Demo script shows early repayment and rollover.

---

## Phase 6 — Settlement improvements

**Goal:** Partial settlement, netting, and settlement records.

| Step | Task | Files |
|------|------|-------|
| 6.1 | Partial release — release a portion of a collateral position | `src/CollateralManager.sol`, `src/SettlementCoordinator.sol` |
| 6.2 | Settlement records — store settlement details on-chain (not just audit log) | `src/SettlementCoordinator.sol` |
| 6.3 | Netting engine — net opposing obligations between counterparty pairs before settlement | `src/SettlementCoordinator.sol` (new) |
| 6.4 | Tests: partial release, settlement record, netting | `test/unit/SettlementCoordinator.t.sol` |

**Exit:** `forge test` passes. Demo shows partial settlement and netting.

---

## Phase 7 — Expanded asset universe

**Goal:** Dynamic asset onboarding and multiple asset types.

| Step | Task | Files |
|------|------|-------|
| 7.1 | Allow updating asset metadata (ISIN, rating, maturity) after registration | `src/AssetRegistry.sol` |
| 7.2 | Add asset types: MUNICIPAL_BOND, EQUITY, ABS, ETF, COMMERCIAL_PAPER | `src/AssetRegistry.sol` |
| 7.3 | Per-issuer eligibility policies in addition to per-type | `src/EligibilityPolicy.sol` |
| 7.4 | Rating migration — track changes, auto-adjust haircuts | `src/EligibilityPolicy.sol`, `src/AssetRegistry.sol` |
| 7.5 | Tests: metadata update, new types, per-issuer policy, rating change | `test/unit/AssetRegistry.t.sol`, `test/unit/EligibilityPolicy.t.sol` |

**Exit:** `forge test` passes. Demo registers corporate bond with per-issuer policy.

---

## Phase 8 — Multi-currency support

**Goal:** Collateral and settlement support multiple currencies.

| Step | Task | Files |
|------|------|-------|
| 8.1 | Replace MockUSD with configurable multi-currency CashToken | `src/CashToken.sol` |
| 8.2 | FX rate oracle — signed FX rates from authorized providers | `src/FxOracle.sol` (new) |
| 8.3 | Cross-currency margin — requirements in one currency, collateral in another | `src/MarginManager.sol` |
| 8.4 | Cross-currency repo — cash leg in different currency from collateral | `src/RepoManager.sol` |
| 8.5 | Tests: multi-currency settlement, FX conversion, cross-currency margin | `test/unit/CashToken.t.sol`, `test/unit/MarginManager.t.sol` |

**Exit:** `forge test` passes. Demo shows EUR collateral, USD cash settlement.

---

## Phase 9 — Chainlink price feeds

**Goal:** Replace custom oracle with Chainlink Data Feeds (or support both).

| Step | Task | Files |
|------|------|-------|
| 9.1 | `ChainlinkPriceFeed` adapter implementing the same price interface | `src/oracle/ChainlinkPriceFeed.sol` (new) |
| 9.2 | `PriceAggregator` — reads from Chainlink first, falls back to custom oracle | `src/oracle/PriceAggregator.sol` (new) |
| 9.3 | Wire `EligibilityPolicy` and `MarginManager` to use `PriceAggregator` | `src/EligibilityPolicy.sol`, `src/MarginManager.sol` |
| 9.4 | Tests: Chainlink feed integration, fallback behavior | `test/unit/ChainlinkPriceFeed.t.sol` |

**Exit:** `forge test` passes. Elgibility and margin use Chainlink prices on testnet.

---

## Phase 10 — L2 testnet deployment

**Goal:** Deploy and verify on Base Sepolia and Arbitrum Sepolia.

| Step | Task | Files |
|------|------|-------|
| 10.1 | Deployment script for Base Sepolia with constructor args | `script/DeployBase.s.sol` |
| 10.2 | Deployment script for Arbitrum Sepolia with constructor args | `script/DeployArbitrum.s.sol` |
| 10.3 | Verify contracts on Blockscout / Etherscan for both chains | Deployment scripts |
| 10.4 | End-to-end demo on Base Sepolia (pledge, repo, margin, substitute) | `script/DemoBase.s.sol` |
| 10.5 | Document gas costs and deployment addresses | `deployments/base-sepolia.json`, `deployments/arbitrum-sepolia.json` |

**Exit:** Contracts deployed and verified on both testnets. Demo runs on Base Sepolia.

---

## Phase 11 — Chainlink Keepers

**Goal:** Automated margin monitoring and time-triggered operations.

This is the production replacement for the CLI `watch` operator built in
Phase 4. The on-chain `evaluateAll`/`evaluateMargin` surface stays the same;
the keeper simply becomes the invocation actor (Chainlink Automation) feeding
it, so the two-actor model (data provider + operator) holds throughout.

| Step | Task | Files |
|------|------|-------|
| 11.1 | `MarginKeeper` — Chainlink Automation compatible, evaluates all obligations on price update | `src/automation/MarginKeeper.sol` (new) |
| 11.2 | `RepoMaturityKeeper` — triggers repayAndClose eligibility at maturity | `src/automation/RepoMaturityKeeper.sol` (new) |
| 11.3 | Register keepers on Base Sepolia and fund with LINK | Deployment scripts |
| 11.4 | Tests: keeper trigger conditions, edge cases | `test/unit/MarginKeeper.t.sol`, `test/unit/RepoMaturityKeeper.t.sol` |

**Exit:** Keepers registered and funded on testnet. Margin calls fire automatically.

---

## Phase 12 — The Graph subgraph

**Goal:** Index all on-chain events for frontend consumption.

| Step | Task | Files |
|------|------|-------|
| 12.1 | Define subgraph schema (entities for Position, Repo, MarginCall, Audit) | `subgraph/schema.graphql` |
| 12.2 | Write mapping functions for all contract events | `subgraph/src/` |
| 12.3 | Deploy subgraph to The Graph testnet (Base Sepolia) | `subgraph/subgraph.yaml` |
| 12.4 | Test queries: positions by owner, active repos, margin call history | `subgraph/test/` |

**Exit:** Subgraph deployed and queryable. Frontend can read indexed state.

---

## Phase 13 — OpenZeppelin Defender

**Goal:** Upgradeability, pause, and operational security.

| Step | Task | Files |
|------|------|-------|
| 13.1 | Deploy CollateralManager behind UUPS proxy | `script/DeployUUPS.s.sol` |
| 13.2 | Deploy ProtocolAccessManager behind UUPS proxy | `script/DeployUUPS.s.sol` |
| 13.3 | Add pause/unpause to CollateralManager (emergency circuit breaker) | `src/CollateralManager.sol` |
| 13.4 | Document upgrade procedure with timelock | `specs/upgrade-procedure.md` |
| 13.5 | Test: upgrade proxy, pause/unpause, verify state preserved | `test/integration/Upgrade.t.sol` |

**Exit:** Proxies deployed on testnet. Pause tested. Upgrade procedure documented.

---

## Phase 14 — TypeScript SDK

**Goal:** Client library for frontends and backends.

| Step | Task | Files |
|------|------|-------|
| 14.1 | Project setup — TypeScript, viem, typechain-types | `sdk/package.json` |
| 14.2 | Typed helpers for CollateralManager functions | `sdk/src/collateral.ts` |
| 14.3 | Typed helpers for RepoManager, MarginManager, SettlementCoordinator | `sdk/src/` |
| 14.4 | Event parsers for all contract events | `sdk/src/events.ts` |
| 14.5 | Transaction builder with gas estimation | `sdk/src/transactions.ts` |
| 14.6 | Unit tests and integration test against Anvil | `sdk/test/` |

**Exit:** SDK published to npm (or local). Tests pass against Anvil.

---

## Phase 15 — Security audit preparation

**Goal:** Ready for external security audit.

| Step | Task | Files |
|------|------|-------|
| 15.1 | Formal specification of state machine and invariants | `specs/formal-spec.md` |
| 15.2 | Threat model — trust assumptions, attack surfaces | `specs/threat-model.md` |
| 15.3 | Full test coverage report — identify uncovered paths | `test/` |
| 15.4 | NatSpec review — every contract, function, parameter documented | All `src/*.sol` |
| 15.5 | Static analysis — run Slither, Mythril, Aderyn | CI pipeline |
| 15.6 | External audit engagement | — |

**Exit:** Audit package ready. External audit initiated.

---

## Phase 16 — Production mainnet

**Goal:** Deploy to Base or Arbitrum mainnet.

| Step | Task | Files |
|------|------|-------|
| 16.1 | Multi-sig admin setup (Gnosis Safe) | `scripts/` |
| 16.2 | Mainnet deployment with verified sources | Deployment scripts |
| 16.3 | Bug bounty program setup | Documentation |
| 16.4 | Incident response runbook | `specs/incident-response.md` |
| 16.5 | Operational monitoring and alerting | Off-chain infrastructure |

**Exit:** Contracts live on mainnet. Monitoring active. Bug bounty live.
