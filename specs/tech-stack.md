# Tech Stack

## Core

| Layer | Technology | Rationale |
|-------|-----------|-----------|
| Language | Solidity ^0.8.24 | EVM-compatible, Cancun target, custom errors |
| Framework | Foundry (forge, anvil, cast) | 100% Solidity toolchain — tests, scripts, deployment |
| License | Apache-2.0 | Permissive, institutional-friendly |

## Smart Contract Architecture

| Component | Contract | Role |
|-----------|----------|------|
| Access | `ProtocolAccessManager` | Central RBAC — roles: ADMIN, BANK, CSD, CUSTODIAN, COLLATERAL_AGENT, VALUATION_PROVIDER, SETTLEMENT_AGENT, COMPLIANCE_PROVIDER, POLICY_ADMIN, TOKEN_CONTROLLER |
| State | `CollateralManager` | Core state machine and position ledger |
| Workflow | `PledgeManager` | Pledge and substitution orchestration |
| Workflow | `RepoManager` | Repo lifecycle (create, settle, repay, default) |
| Workflow | `SettlementCoordinator` | DvP settlement — cash and collateral legs |
| Workflow | `MarginManager` | Margin requirements and margin call lifecycle |
| Attestation | `AttestationRegistry` | Signed custody attestations (ECDSA) |
| Attestation | `ComplianceAttestationRegistry` | Signed compliance attestations (ECDSA) |
| Registry | `AssetRegistry` | Asset identity (ISIN, type, maturity, rating) |
| Registry | `CustodyRegistry` | Custody state mirror with encumbrance tracking |
| Policy | `EligibilityPolicy` | Configurable eligibility engine with haircuts |
| Oracle | `ValuationOracle` | Signed price oracle with staleness protection |
| Token | `TokenizedSecurity` | Controlled ERC-20 for securities |
| Token | `CashToken` | MockUSD settlement token (POC only) |
| Audit | `AuditRegistry` | Append-only event log |
| Library | `Roles` | Role identifier constants |
| Library | `SignatureVerifier` | ECDSA signature verification |

## Planned Additions

### Oracle — Chainlink Data Feeds

**What:** Replace or supplement the custom `ValuationOracle` with
Chainlink Data Feeds for market prices.

**Why:** Chainlink feeds provide decentralized, tamper-resistant price data
with built-in staleness checks and deviation thresholds. The custom oracle
remains as a fallback for assets not covered by Chainlink.

**Integration point:** `EligibilityPolicy.getCollateralValue()` and
`MarginManager.createMarginCall()` read prices through the oracle layer.

**Status:** Not yet implemented.

### Cross-chain — Chainlink CCIP

**What:** Use Chainlink CCIP to synchronize collateral state across multiple
L2 deployments (Base, Arbitrum).

**Why:** Institutions may deploy on different L2s. Cross-chain collateral
tracking ensures positions are visible across chains without a centralized
coordinator.

**Integration point:** A new `CrossChainSettlement` contract would send/
receive CCIP messages to coordinate collateral state between chains.

**Status:** Not yet implemented. Single-chain only.

### Automation — Chainlink Keepers

**What:** Automate margin monitoring, repo maturity triggers, price update
submission, and attestation renewal.

**Why:** Manual transaction submission does not scale. Keepers evaluate
conditions on-chain and trigger the appropriate workflow functions.

**Integration points:**
- `MarginManager.createMarginCall()` — evaluate on every price update
- `RepoManager.repayAndClose()` — trigger at maturity
- `ValuationOracle.updatePrice()` — periodic price refresh

**Status:** Not yet implemented. All operations are manual.

### Indexing — The Graph

**What:** Deploy a subgraph to index all collateral events, position state
changes, repo lifecycle events, and margin calls.

**Why:** Frontends and dashboards need queryable, real-time views of on-chain
state. Direct contract calls are expensive for bulk reads.

**Integration point:** Index events from CollateralManager, RepoManager,
MarginManager, SettlementCoordinator, and AuditRegistry.

**Status:** Not yet implemented. No `subgraph/` directory exists yet.

### Security — OpenZeppelin Defender

**What:** Use Defender for UUPS proxy upgradeability, pause mechanisms,
and operational security.

**Why:** Production deployment requires the ability to upgrade contracts
in response to bugs or new features. Defender provides the infrastructure
for secure upgrade execution with timelock and multisig approval.

**Integration point:** Wrap core contracts (CollateralManager,
ProtocolAccessManager) behind UUPS proxies.

**Status:** Not yet implemented. All contracts are immutable.

### Client Library — TypeScript SDK

**What:** A TypeScript client library for frontends, backends, and scripts
to interact with the deployed contracts.

**Why:** Direct ethers.js/viem contract interactions are verbose and
error-prone. An SDK provides typed functions, event parsing, and
transaction builders.

**Integration point:** Wraps contract ABIs, provides typed helpers for
every workflow function, and handles transaction signing.

**Status:** Not yet implemented. No `sdk/` directory exists yet.

## Trust Model

The Collateral Network uses its own `ProtocolAccessManager` for role-based
access control. It does **not** depend on ONCHAINID, ERC-3643, or any
external identity framework.

| Role | Purpose |
|------|---------|
| `ADMIN` | Bootstrap, grant/revoke roles |
| `BANK` | Pledge, substitute, release collateral; create repos |
| `CSD` | Issue/revoke custody attestations |
| `CUSTODIAN` | Submit custody attestations |
| `COLLATERAL_AGENT` | Verify, approve, enforce collateral |
| `VALUATION_PROVIDER` | Submit signed market prices |
| `SETTLEMENT_AGENT` | Execute settlement coordinator |
| `COMPLIANCE_PROVIDER` | Submit compliance attestations |
| `POLICY_ADMIN` | Configure eligibility policies and haircuts |
| `TOKEN_CONTROLLER` | Mint, burn, transfer tokenized securities |

## Deployment Targets

| Environment | Chain | Purpose |
|-------------|-------|---------|
| Local | Anvil (port 8545) | Development, testing, demo |
| Testnet | Base Sepolia | L2 testnet validation |
| Testnet | Arbitrum Sepolia | L2 testnet validation |
| Mainnet | Base | Production (future) |
| Mainnet | Arbitrum | Production (future) |
