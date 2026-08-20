# Institutional Collateral Network

A Solidity-based protocol for managing collateralized securities lending, repo transactions, and margin operations on Ethereum-compatible blockchains. Built with Foundry.

---

## Overview

The Institutional Collateral Network digitizes the lifecycle of financial collateral management — from asset tokenization and custody attestation through pledging, settlement, margin calls, substitution, and repo maturity. It models a permissioned network where banks, custodians, a central securities depository (CSD), and various agents interact through well-defined roles and workflows.

The system separates **state management** (CollateralManager) from **workflow orchestration** (PledgeManager, RepoManager, SettlementCoordinator, MarginManager). Participants never call the state machine directly — only registered operator contracts may mutate collateral state.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      ProtocolAccessManager                      │
│                  (role-based access control)                    │
└─────────────────────────────────────────────────────────────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
   ┌────▼────┐          ┌────▼────┐          ┌────▼────┐
   │  BANK   │          │  CSD    │          │CUSTODIAN│
   └────┬────┘          └────┬────┘          └────┬────┘
        │                    │                     │
        │            ┌───────▼───────┐      ┌──────▼──────┐
        │            │  Attestation  │      │   Custody   │
        │            │   Registry    │◄─────│   Registry  │
        │            └───────────────┘      └─────────────┘
        │                    │                     │
   ┌────▼────────────────────▼─────────────────────▼────┐
   │              CollateralManager                      │
   │         (state machine + position ledger)           │
   │  AVAILABLE → RESERVED → PLEDGED → RELEASE_REQUESTED│
   │                   └→ RELEASED                      │
   │                   └→ DEFAULTED → RECOVERY          │
   └──┬────────────┬─────────────┬──────────────────┬───┘
      │            │             │                  │
┌─────▼─────┐ ┌───▼────┐ ┌─────▼──────┐    ┌──────▼──────┐
│  Pledge   │ │ Margin │ │ Settlement │    │    Repo     │
│  Manager  │ │Manager │ │ Coordinator│    │   Manager   │
└───────────┘ └────────┘ └────────────┘    └─────────────┘
```

---

## Core Components

### Infrastructure

| Contract | Purpose |
|---|---|
| `ProtocolAccessManager` | Central role-based access control. Roles: ADMIN, BANK, CSD, CUSTODIAN, COLLATERAL_AGENT, VALUATION_PROVIDER, SETTLEMENT_AGENT, COMPLIANCE_PROVIDER, POLICY_ADMIN, TOKEN_CONTROLLER. |
| `AssetRegistry` | Maintains on-chain identity of securities (ISIN, type, maturity, rating). Links each asset to a TokenizedSecurity contract. |
| `AttestationRegistry` | Stores signed custody attestations from the CSD/Custodian. |
| `CustodyRegistry` | On-chain mirror of current custody state per asset. Ownership and quantity change only through valid attestations; encumbrance changes only through the CollateralManager. |
| `ComplianceAttestationRegistry` | Signed compliance attestations (KYC/AML/sanctions) for participants. |
| `AuditRegistry` | Append-only log of all collateral, repo, settlement, and margin events. |

### Token Layer

| Contract | Purpose |
|---|---|
| `TokenizedSecurity` | Controlled ERC-20 representation of an underlying security. Mint/burn/forceTransfer restricted to TOKEN_CONTROLLER. Supports freeze/unfreeze. |
| `CashToken` | MockUSD — a minimal ERC-20 used as settlement cash in the POC. |

### Collateral Management

| Contract | Purpose |
|---|---|
| `CollateralManager` | Core state machine and position ledger. Enforces the lifecycle (AVAILABLE → RESERVED → PLEDGED → RELEASED / DEFAULTED → RECOVERY). Only registered operator contracts may call it. |
| `PledgeManager` | Workflow orchestration for pledge and substitution flows. Enforces who (provider / receiver / agent) may do what, delegates state transitions to CollateralManager. |
| `EligibilityPolicy` | Configurable eligibility engine. V1: Treasury (5% haircut), Corporate Bond ≥ AA (10% haircut, 90-day minimum term). |
| `ValuationOracle` | Signed price oracle. Prices from authorized VALUATION_PROVIDER, ECDSA-verified, 5-minute staleness window. |

### Settlement & Repos

| Contract | Purpose |
|---|---|
| `SettlementCoordinator` | Atomic DvP settlement. Orchestrates the cash and collateral legs of repo settlement. |
| `RepoManager` | Simplified repo (sell-and-repurchase) facility. Handles creation, settlement, repayment with interest, and default marking. |
| `MarginManager` | Maintains collateral requirements per obligation. Evaluates live mark-to-market value and issues margin calls on shortfall. |

---

## Collateral Lifecycle

### Pledge Flow
```
1. Provider   → requestPledge          (creates AVAILABLE position)
2. Agent      → verifyCollateral       (eligibility + custody + price + haircut)
3. Provider   → reserveCollateral      (locks tokens, mirrors CSD encumbrance)
4. Receiver   → approvePledge          (marks approved)
5. Provider   → finalizePledge         (status = PLEDGED)
```

### Substitution Flow
```
1. Provider   → requestSubstitution    (creates AVAILABLE replacement)
2. Agent      → validateReplacement    (replacement value ≥ old value)
3. Provider   → reserveReplacement     (locks replacement)
4. Provider   → activateSubstitution   (releases OLD, activates NEW)
```

### Repo Flow
```
1. Borrower   → createRepo             (links collateral to repo obligation)
2. Lender     → settleRepo             (DvP: cash → borrower, collateral stays locked)
3. Borrower   → repayAndClose          (principal + interest repaid, collateral released)
```

### Margin Call Flow
```
1. Bank/Agent → setRequirement         (collateral value requirement for obligation)
2. Bank/Agent → createMarginCall       (evaluates live value, issues call on shortfall)
3. Provider   → post additional collateral (via substitution)
4. Bank/Agent → satisfyMarginCall      (re-evaluates, marks satisfied if adequate)
```

---

## Roles

| Role | Description |
|---|---|
| `ADMIN` | System bootstrap. Grants/revokes roles. Deploys infrastructure. |
| `BANK` | Pledges/substitutes/releases own collateral. Creates repos. |
| `CSD` | Issues/revoke asset attestations (off-chain authoritative source). |
| `CUSTODIAN` | Submits signed custody attestations. |
| `COLLATERAL_AGENT` | Verifies/approves collateral workflows. Can default/enforce. |
| `VALUATION_PROVIDER` | Submits signed market prices. |
| `SETTLEMENT_AGENT` | Executes settlement coordinator. |
| `COMPLIANCE_PROVIDER` | Submits compliance attestations. |
| `POLICY_ADMIN` | Configures eligibility policies and haircuts. |
| `TOKEN_CONTROLLER` | Mints/burns/transfers tokenized securities (Admin + CollateralManager). |

---

## Supported Assets (V1)

| Asset | ISIN | Type | Rating | Haircut | Min Term |
|---|---|---|---|---|---|
| T-BOND-001 | US-TBOND-001 | Treasury | Unrated | 5% | — |
| CORP-BOND-001 | IN-CORP-001 | Corporate Bond | AA | 10% | 90 days |

---

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

### Install Dependencies

```bash
forge install
```

### Build

```bash
forge build
```

### Run Tests

```bash
forge test
```

### Deploy to Local Anvil Node

```bash
# Terminal 1: start a local node
anvil

# Terminal 2: deploy the full network
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

This writes all deployed addresses to `deployments/anvil.json`.

### Run End-to-End Demo

```bash
# After deploying:
forge script script/Demo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

The demo executes the full lifecycle:
1. Custody attestation for 10,000 T-BOND-001
2. Token minting for Bank A
3. Market price submission ($100)
4. Collateral pledge (5% haircut → $950,000 collateral value)
5. Repo settlement (DvP: $950,000 cash delivery)
6. Price drop to $92 → margin call ($26,000 shortfall)
7. Substitution with corporate bonds
8. Margin call satisfied
9. Repo maturity: repayment + collateral release

#### Phase Control

For live broadcast runs, the demo supports phase splitting:

```bash
# Phase 1: attestation through margin call satisfied
DEMO_PHASE=1 forge script script/Demo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast

# Phase 2: repo maturity + release (advances clock past maturity)
DEMO_PHASE=2 forge script script/Demo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

---

## Project Structure

```
collateral/
├── src/
│   ├── CollateralManager.sol          # Core state machine
│   ├── PledgeManager.sol              # Pledge/substitution workflow
│   ├── MarginManager.sol              # Margin requirements & calls
│   ├── SettlementCoordinator.sol      # DvP settlement
│   ├── RepoManager.sol                # Repo lifecycle
│   ├── AssetRegistry.sol              # Asset identity registry
│   ├── AttestationRegistry.sol        # Signed attestations
│   ├── CustodyRegistry.sol            # Custody state mirror
│   ├── ComplianceAttestationRegistry.sol  # Compliance attestations
│   ├── AuditRegistry.sol              # Audit trail
│   ├── ProtocolAccessManager.sol      # Role-based access control
│   ├── EligibilityPolicy.sol          # Eligibility & haircut engine
│   ├── ValuationOracle.sol            # Signed price oracle
│   ├── TokenizedSecurity.sol          # Controlled security token
│   ├── CashToken.sol                  # MockUSD settlement token
│   ├── interfaces/                    # Interfaces (ICollateralManager, ICashToken, ITokenizedSecurity)
│   └── libs/                          # Libraries (Roles, SignatureVerifier)
├── script/
│   ├── Deploy.s.sol                   # Full deployment script
│   ├── Demo.s.sol                     # End-to-end demo
│   ├── LibConstants.sol               # Deterministic test constants
│   └── TimeProbe.s.sol                # Time simulation helper
├── test/
│   ├── unit/                          # Unit tests per contract
│   ├── integration/                   # Integration tests (repo flow)
│   ├── Demo.t.sol                     # Demo test wrapper
│   └── TestBase.sol                   # Shared test setup
├── deployments/
│   └── anvil.json                     # Local deployment artifact
├── foundry.toml                       # Foundry configuration
└── foundry.lock                       # Dependency lock file
```

---

## Key Design Decisions

- **State vs. Workflow separation**: CollateralManager holds state; workflow contracts (PledgeManager, etc.) enforce authorization. Participants cannot mutate collateral directly.
- **Custody mirror with encumbrance**: CustodyRegistry mirrors off-chain custody state and tracks on-chain encumbrance. Double-pledging is prevented at both token and custody layers.
- **Signed attestations**: Custody and compliance states are authenticated with ECDSA signatures from authorized providers.
- **Stale price protection**: ValuationOracle enforces a 5-minute price freshness window. Any read of a stale price reverts.
- **Atomic substitution**: Replacement collateral is locked before the old collateral is released, maintaining continuous coverage.
- **Deterministic position IDs**: Position IDs are derived from `(sender, counter)` without `block.timestamp`, ensuring consistency between simulation and broadcast.

---

## License

Apache-2.0
