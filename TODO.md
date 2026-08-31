# TODO - Institutional Collateral Network

Feature roadmap toward a production-grade collateral management system
modeled on DTCC Appchain capabilities. The depository (CSD) remains mocked;
collateral management, settlement, and repo logic are on-chain.

**Target chains:** Anvil (local) → Besu consortium (permissioned) → Base / Arbitrum (L2 testnet → mainnet)

---

## Phase 1 — Harden the Existing V1

Fix correctness issues and gaps found in the current codebase before adding
new features.

### 1.1 Critical Fixes

- [ ] **AuditRegistry access control** — the `log()` function is `external`
  with no modifier; any address can write fake audit records. Gate writes to
  registered operator contracts only.
- [ ] **Stale attestation eligibility bypass** — `CustodyRegistry` copies
  custody state on `updateCustodyAttestation` but never re-validates when the
  attestation is later revoked or expires. `EligibilityPolicy.isEligible`
  checks `lastAttestationId != 0` but not whether it is still valid. Fix:
  verify attestation validity on every eligibility check.
- [ ] **Single-owner-per-asset limitation** — `CustodyRegistry` maps
  `assetId => CustodyState` (one state per ISIN). If two banks hold the same
  ISIN, the second attestation overwrites the first. Fix: key custody state on
  `(assetId, owner)` instead of just `assetId`.
- [ ] **`cancelReservation` does not clear `validated` flag** — a cancelled
  position can be re-reserved without re-validation. Clear the flag on cancel.
- [ ] **`isCompliant` reverts on expired attestation** — returns a revert
  instead of `false`, breaking composability. Return `false` gracefully.

### 1.2 Correctness & Edge Cases

- [ ] **Reentrancy guards** — `_lock` / `_release` make external calls to
  `ITokenizedSecurity.forceTransfer()` and `CustodyRegistry.applyEncumbrance()`.
  Add `nonReentrant` to all state-mutating functions that perform external calls.
- [ ] **Gas-limit protection on `positionsByObligation` iteration** — both
  `CollateralManager.liveCollateralValueForObligation` and
  `RepoManager.repayAndClose` iterate an unbounded array. Add a page/batch
  mechanism or enforce a maximum positions-per-obligation cap.
- [ ] **`positionsByObligation` cleanup** — positions remain in the array after
  release/default. Add removal or a bounded iteration with cursor-based views.
- [ ] **Inconsistent error style** — `createReplacementPosition` mixes
  `require(msg, string)` with custom errors. Standardize on custom errors
  throughout.
- [ ] **Missing events** — no events for `cancelReservation`, `markApproved`,
  or `markDefault` at the CollateralManager level. Add them.
- [ ] **`PledgeManager.approveRelease` counter-party logic** — the comment says
  "provider can approve if receiver requested" but the code allows either party
  always. Enforce or correct the comment.

### 1.3 Test Coverage

- [ ] **Invariant / fuzz tests** — `foundry.toml` configures `[invariant]` but
  no invariant test files exist. Add invariant tests for:
  - Collateral accounting invariant: `total == reserved + pledged + available`
  - Custody encumbrance never exceeds total quantity
  - Position status machine transitions (no invalid state jumps)
- [ ] **Attestation expiry + eligibility** — test that expired/revoked
  attestations do not grant eligibility after submission.
- [ ] **Multi-owner custody** — test (and fix) two banks holding the same ISIN.
- [ ] **`cancelReservation` + re-validation** — test that cancelled positions
  require fresh validation.
- [ ] **`isCompliant` on expired attestation** — test returns false, not reverts.
- [ ] **AuditRegistry unauthorized writes** — test that non-operator addresses
  cannot write audit records (after fix).
- [ ] **Gas stress test** — test obligation with many substituted positions to
  verify iteration does not revert.

---

## Phase 2 — Core Feature Gaps

Features that DTCC Appchain provides and the current V1 lacks entirely.

### 2.1 Collateral Optimization Engine

- [ ] **Automated collateral substitution recommendations** — given a set of
  pledged positions and a target eligibility/risk profile, compute the optimal
  set of substitutions (cheapest-to-borrow, haircut-minimizing).
- [ ] **Real-time collateral inventory view** — aggregated on-chain view of
  all positions across all obligations, filterable by asset type, owner,
  status, eligibility.
- [ ] **Utilization metrics** — on-chain tracking of collateral utilization
  rates (encumbered / total) per asset, per owner, system-wide.
- [ ] **Concentration limits** — configurable per-counterparty and per-asset
  type concentration caps enforced at pledge time.

### 2.2 Advanced Margin Management

- [ ] **Automated margin monitoring** — event-driven evaluation: on every price
  update, re-evaluate all active obligations and trigger margin calls
  automatically when shortfall is detected.
- [ ] **Margin call history** — store a bounded history of margin calls per
  obligation (not just the latest). Include timestamps, shortfall amounts,
  resolution status.
- [ ] **Partial margin calls** — allow posting partial additional collateral
  to reduce (not just satisfy) a shortfall.
- [ ] **Late margin penalties** — configurable penalty rate for unsatisfied
  margin calls past a grace period.
- [ ] **Margin call preview (view)** — a `previewMarginCall(obligationId)`
  function that returns the shortfall without reverting.

### 2.3 Repo Enhancements

- [ ] **Early repayment** — allow `repayAndClose` before maturity with
  pro-rata interest (ACT/360 or 30/360 day-count convention).
- [ ] **Repo renewal / rollover** — close an expiring repo and open a new one
  against the same (or substituted) collateral in a single atomic transaction.
- [ ] **Grace period** — configurable grace period after maturity before default
  can be triggered.
- [ ] **Late repayment penalty** — additional interest accrual for repayment
  after maturity.
- [ ] **Compound interest option** — support compound (not just simple)
  interest calculation.
- [ ] **Multi-collateral repo** — allow a single repo to reference multiple
  collateral positions natively (not only via substitution).
- [ ] **Repo open market** — allow any BANK to be a lender (not just the
  original receiver).

### 2.4 Settlement Enhancements

- [ ] **Partial settlement / partial release** — allow settling/releasing a
  portion of a collateral position.
- [ ] **Netting engine** — net opposing obligations across multiple repos
  or trades between the same counterparty pair before settlement.
- [ ] **Payment-versus-Payment (PvP)** — atomic swap of two cash legs in
  different currencies with FX rate attestation.
- [ ] **Settlement records** — store settlement details on-chain (not just
  audit log). Include settlement timestamp, amounts, parties, method.
- [ ] **CLS-style payment orchestration** — ensure both legs of DvP settle
  atomically or neither does (current implementation is already atomic but
  does not handle partial failures).

### 2.5 Securities Lending (Beyond Repo)

- [ ] **Securities lending facility** — borrow/lend securities without a cash
  leg. Fee-based (borrower pays a borrow fee to the lender).
- [ ] **Recall mechanism** — lender can recall lent securities with configurable
  notice period.
- [ ] **Fee accrual** — on-chain tracking of accrued borrow fees over time.
- [ ] **Utilization-based pricing** — dynamic borrow fee based on asset
  utilization (high demand → higher fee).

---

## Phase 3 — Multi-Asset, Multi-Currency

### 3.1 Expanded Asset Universe

- [ ] **Dynamic asset onboarding** — allow new assets to be registered and
  activated without redeploying. Remove the V1 "two securities" limit.
- [ ] **Asset metadata updates** — allow updating ISIN, rating, maturity,
  issuer after registration (currently immutable).
- [ ] **Additional asset types** — add policies for: MUNICIPAL_BOND, EQUITY,
  ABS (asset-backed security), ETF, REPO_RECEIPT, COMMERCIAL_PAPER.
- [ ] **Rating migration** — track rating changes over time. Auto-adjust
  eligibility/haircut when a rating changes.
- [ ] **Per-issuer eligibility policies** — in addition to per-type policies,
  allow issuer-specific eligibility rules (e.g., exclude specific issuers).
- [ ] **Asset lifecycle events** — maturity handling: auto-deactivate at
  maturity, force-release any remaining pledged positions, convert token to
  cash value.

### 3.2 Multi-Currency Support

- [ ] **Multi-currency CashToken** — replace MockUSD with a configurable
  multi-currency token (or integrate with existing stablecoins: USDC, USDT,
  DAI, EURC).
- [ ] **FX rate oracle** — signed FX rates from authorized providers. Use for
  cross-currency margin, cross-currency settlement.
- [ ] **Cross-currency margin** — margin requirements denominated in one
  currency, collateral valued in another, with live FX conversion.
- [ ] **Multi-currency repo** — repo where cash leg is in a different currency
  from the collateral's denomination.

### 3.3 Accrued Interest & Corporate Actions

- [ ] **Coupon distribution** — tokenized securities that represent bonds
  should support coupon accrual and distribution to holders.
- [ ] **Accrued interest on collateral** — when collateral is pledged, track
  accrued interest that belongs to the provider (not the receiver).
- [ ] **Corporate actions** — stock splits, mergers, calls: update token
  quantities and eligibility metadata atomically.

---

## Phase 4 — Risk Management & Compliance

### 4.1 Risk Engine

- [ ] **Value-at-Risk (VaR) calculation** — on-chain VaR for collateral
  portfolios based on historical price volatility.
- [ ] **Stress testing** — configurable stress scenarios (e.g., "what if
  Treasury prices drop 20%?") evaluated on-chain.
- [ ] **Wrong-way risk detection** — identify correlations between counterparty
  credit risk and collateral value (e.g., bank's own bonds as collateral).
- [ ] **Collateral substitution triggers** — automatically suggest or execute
  substitution when risk metrics breach thresholds.
- [ ] **Counterparty exposure tracking** — real-time aggregate exposure per
  counterparty across all obligations.

### 4.2 Regulatory Compliance

- [ ] **Automated regulatory reporting** — generate on-chain compliance reports
  (e.g., SEC Rule 15c3-1, Basel III collateral requirements).
- [ ] **Jurisdiction-specific rules engine** — configurable rules per
  jurisdiction (which assets are eligible, maximum haircuts, reporting
  requirements).
- [ ] **Sanctions screening integration** — real-time integration with
  sanctions lists (OFAC, EU). Freeze positions of sanctioned entities.
- [ ] **Beneficial ownership tracking** — on-chain tracking of ultimate
  beneficial owners for compliance.
- [ ] **Compliance attestation history** — retain full history of compliance
  attestations (current implementation deletes on revocation).

### 4.3 Dispute Resolution

- [ ] **On-chain dispute mechanism** — parties can raise disputes over margin
  calls, collateral valuations, or settlement failures.
- [ ] **Arbitration workflow** — designated arbitrator role resolves disputes
  with binding on-chain rulings.
- [ ] **Penalty calculation** — automated penalty/compensation calculation
  based on dispute outcome and contractual terms.

---

## Phase 5 — Production Infrastructure

### 5.1 Oracle Infrastructure

- [ ] **Chainlink integration** — replace the custom signed oracle with
  Chainlink Data Feeds for market prices (or support both).
- [ ] **Multi-oracle aggregation** — support multiple price providers with
  median aggregation, outlier rejection.
- [ ] **TWAP (time-weighted average price)** — compute TWAP for collateral
  valuation to reduce manipulation risk.
- [ ] **Configurable staleness window** — make `MAX_PRICE_AGE` a governance
  parameter instead of a hardcoded constant.
- [ ] **Off-chain signing service** — middleware for custodians and valuation
  providers to sign attestations off-chain and submit via relayers.

### 5.2 Upgradeability & Governance

- [ ] **UUPS proxy pattern** — deploy core contracts behind proxies for
  upgradability. Critical for production deployment.
- [ ] **DAO governance** — governance token or multisig to vote on protocol
  parameter changes (haircuts, eligibility policies, fee rates).
- [ ] **Timelock on parameter changes** — delay between governance vote and
  execution for critical parameters.
- [ ] **Emergency pause** — circuit breaker to pause all collateral operations
  in case of exploit or critical bug.
- [ ] **Protocol fee structure** — configurable fees for settlement, repo,
  substitution, margin calls.

### 5.3 L2 Deployment

- [ ] **Base deployment** — deploy and test on Base Sepolia testnet.
- [ ] **Arbitrum deployment** — deploy and test on Arbitrum Sepolia testnet.
- [ ] **Cross-chain collateral tracking** — if deployed on multiple L2s, track
  collateral positions across chains.
- [ ] **L1 ↔ L2 bridge integration** — if the CSD or custodian operates on L1,
  bridge attestation state to the L2 collateral layer.
- [ ] **Gas optimization for L2** — calldata compression, L2-specific opcode
  usage, batch submission of attestations.

### 5.4 Monitoring & Operations

- [ ] **Event indexer** — off-chain service (subgraph or custom) to index all
  on-chain events for dashboard consumption.
- [ ] **Operational dashboard** — real-time view of: total collateral locked,
  active repos, margin call status, system utilization, audit trail.
- [ ] **Alerting system** — threshold-based alerts (margin call triggered,
  price stale, attestation expiring, position approaching concentration limit).
- [ ] **Keeper network** — incentivized bots that automate margin evaluation,
  price updates, and time-triggered operations (repo maturity, attestation
  renewal).
- [ ] **Audit trail explorer** — queryable interface for the AuditRegistry
  (filter by type, party, time range, position).

---

## Phase 6 — Advanced Features (DTCC Parity)

### 6.1 Tri-party Collateral Management

- [ ] **Tri-party agent role** — a new role for a tri-party agent (like BNY
  Mellon or JP Morgan) that manages collateral allocation on behalf of both
  parties.
- [ ] **Automated collateral allocation** — tri-party agent algorithm
  allocates optimal collateral from a provider's inventory to meet a
  receiver's requirements.
- [ ] **Tri-party settlement** — settlement through the tri-party agent
  (agent holds collateral in a segregated account, manages margin, handles
  substitution).
- [ ] **Tri-party billing** — automated fee calculation and invoicing for
  tri-party services.

### 6.2 Collateral Transformation

- [ ] **Automated transformation** — system automatically transforms collateral
  when eligibility changes (e.g., downgrade triggers substitution to eligible
  asset).
- [ ] **Transformation cost optimization** — minimize transaction costs when
  selecting replacement collateral (haircut savings vs. substitution cost).
- [ ] **Eligibility migration workflows** — when an asset type becomes
  ineligible (e.g., policy change), migrate all affected positions within a
  configurable window.

### 6.3 Cross-border & Multi-jurisdiction

- [ ] **Multi-jurisdiction support** — support collateral across different
  legal jurisdictions with varying rules.
- [ ] **Regulatory capital calculation** — on-chain calculation of regulatory
  capital requirements (CVA, DVA, collateral capital).
- [ ] **Cross-border settlement coordination** — handle time-zone differences,
  settlement cycles, and holiday calendars across jurisdictions.

### 6.4 Advanced Tokenization

- [ ] **Fractional ownership** — support sub-unit ownership of securities
  (current `decimals = 0` for TokenizedSecurity).
- [ ] **Token maturity conversion** — automatically convert token to cash
  value at maturity (bond redemption).
- [ ] **Multi-token collateral** — single position backed by a basket of
  different tokens.
- [ ] **Token wrapping** — wrap external tokens (ERC-20 stablecoins, NFTs,
  other security tokens) as eligible collateral.

---

## Phase 7 — Testing & Auditing

### 7.1 Comprehensive Testing

- [ ] **Full invariant test suite** — property-based testing of all invariants:
  accounting, state machine, custody, eligibility.
- [ ] **Fuzz testing** — Foundry fuzz tests for all external functions with
  edge cases (zero amounts, max uint, address(0), expired attestations).
- [ ] **Integration test suite** — multi-scenario integration tests:
  - Full repo lifecycle with substitution
  - Multiple simultaneous repos with shared collateral
  - Margin call cascade (price drops trigger multiple calls)
  - Default + enforcement across multiple positions
  - Tri-party flows (when implemented)
- [ ] **Gas benchmarking** — measure and optimize gas costs for all critical
  paths. Document gas limits for each operation.
- [ ] **Soak testing** — long-running tests simulating months of activity
  (hundreds of repos, substitutions, margin calls).

### 7.2 Security Audit Preparation

- [ ] **Formal specification** — write a formal specification of the state
  machine, invariants, and authorization rules.
- [ ] **Threat model** — document the threat model (who can attack what,
  what are the trust assumptions).
- [ ] **External audit** — engage a security firm for a formal audit before
  mainnet deployment.
- [ ] **Bug bounty program** — set up a bug bounty for the deployed contracts.
- [ ] **Incident response plan** — document the emergency pause and upgrade
  procedures.

---

## Priority Legend

| Priority | Meaning |
|----------|---------|
| **P0** | Critical correctness fix — must be done before any new features |
| **P1** | High-impact feature — needed for production-grade collateral management |
| **P2** | Important enhancement — improves feature parity with DTCC Appchain |
| **P3** | Advanced feature — needed for full institutional-grade system |
| **P4** | Nice-to-have — future roadmap items |

---

## Current Status

| Component | Status | Notes |
|-----------|--------|-------|
| CollateralManager | V1 ✅ | Core state machine complete. Needs reentrancy guards, invariant cleanup. |
| PledgeManager | V1 ✅ | Workflow complete. Needs counter-party logic fix. |
| MarginManager | V1 ⚠️ | Manual-only. Needs automated monitoring. |
| RepoManager | V1 ⚠️ | No liquidation, no early repayment, simple interest only. |
| SettlementCoordinator | V1 ✅ | Atomic DvP complete. Needs partial settlement, netting. |
| EligibilityPolicy | V1 ⚠️ | Two asset types only. Needs expanded policies. |
| ValuationOracle | V1 ✅ | Signed prices with staleness. Needs multi-oracle, TWAP. |
| AssetRegistry | V1 ✅ | Needs dynamic metadata updates. |
| CustodyRegistry | V1 ⚠️ | Single-owner-per-asset bug. Needs multi-owner fix. |
| AttestationRegistry | V1 ✅ | Needs cascading revocation. |
| ComplianceAttestationRegistry | V1 ⚠️ | Deletes history on revocation. `isCompliant` reverts. |
| AuditRegistry | V1 ⚠️ | No access control. |
| TokenizedSecurity | V1 ✅ | Needs ERC-165, supply cap. |
| CashToken | Mock ⚠️ | Test-only. Replace with real stablecoin or multi-currency. |
| ProtocolAccessManager | V1 ✅ | Needs time-limited roles, emergency pause. |
| Test suite | V1 ⚠️ | Good unit coverage. Missing invariant/fuzz tests. |
| Deployment | Local ✅ | Local Anvil. Needs Besu consortium + L2 testnet deployment. |
