# Mission

## Purpose

The Collateral Network is a standalone, on-chain protocol for institutional
collateral management. It provides the infrastructure for pledging, substituting,
and releasing securities as collateral; managing repo (sell-and-repurchase)
transactions; executing delivery-versus-payment (DvP) settlement; and
maintaining margin requirements — all with an immutable audit trail.

This project is **independent** of the institutional-rwa-platform. It does not
depend on ERC-3643, ONCHAINID, or Chainlink CCIP for its core functionality.
The two systems may interoperate in the future, but the Collateral Network
stands on its own.

## Principles

1. **State machine integrity.** Every collateral position follows a strict
   lifecycle: AVAILABLE → RESERVED → PLEDGED → RELEASE_REQUESTED → RELEASED,
   with DEFAULTED → RECOVERY as the enforcement path. No state is reachable
   except through the defined transitions.

2. **Separation of state and workflow.** The CollateralManager holds state
   and enforces transitions. Workflow contracts (PledgeManager, RepoManager,
   SettlementCoordinator, MarginManager) enforce actor authorization. No
   participant calls the state machine directly.

3. **Dual-layer custody.** Tokenized securities are locked in the vault
   (token layer) while the CustodyRegistry mirrors the encumbrance in the
   custody layer. Double-pledging is prevented at both layers.

4. **Signed attestations.** Custody and compliance states are authenticated
   with ECDSA signatures from authorized providers. The system trusts the
   signature, not the submitter.

5. **Stale-price protection.** The ValuationOracle enforces a staleness
   window. Any read of an expired price reverts, preventing margin evaluation
   or collateral valuation on stale data.

6. **Role-based access control.** A central ProtocolAccessManager grants
   roles (BANK, CSD, CUSTODIAN, COLLATERAL_AGENT, VALUATION_PROVIDER, etc.)
   to participant addresses. Every mutation is gated by role checks.

7. **Two-actor automation.** Market-data provision and margin enforcement are
   kept as distinct actors. A *data provider* (the VALUATION_PROVIDER, standing
   in for a Chainlink price feed or a tri-party agent delivering collateral
   valuations) signs fresh prices into the oracle. A separate *operator* (the
   COLLATERAL_AGENT, standing in for a margin-desk UI or a Chainlink keeper)
   periodically invokes margin evaluation and, on shortfall, raises the margin
   call that asks for more collateral. In Phase 4 this automation is driven by
   a CLI; a later phase swaps the operator for an on-chain Chainlink keeper.

## Scope

### In scope

- Collateral pledging, verification, reservation, approval, release
- Collateral substitution with atomicity guarantees
- Repo creation, settlement (DvP), repayment, default
- Margin requirement tracking and margin call lifecycle
- CLI/UI-driven margin automation: signed price updates and edge-triggered
  margin checks that raise margin calls when collateral falls short
  (commands and keys in `specs/phase4-cli.md`)
- Signed custody and compliance attestations
- Eligibility policy engine with configurable haircuts
- Signed price oracle with staleness protection
- Comprehensive audit trail for all state transitions
- Mock CSD (depository stays mocked; collateral management is on-chain)

### Out of scope (for now)

- Cross-chain collateral tracking (future phase)
- DAO governance (future phase)
- Securities lending without cash leg (future phase)
- Live tri-party collateral management integration (future phase; the
  tri-party pattern is simulated here by the CLI acting as the tri-party
  agent's operator and data source)
- Production Chainlink price feeds (future phase; the CLI `price update`
  command stands in for a Chainlink feed, so the two-actor automation it
  exercises is feed-compatible)

## Success criteria

1. Any institution can pledge tokenized securities as collateral with full
   audit trail and no possibility of double-pledging.
2. Repo transactions settle atomically (DvP) with collateral locked and
   cash delivered in one transaction.
3. Margin calls are triggered when collateral value falls below requirements,
   with substitution available to cure shortfalls. An operator (CLI, later a
   keeper or margin-desk UI) can update a price, run a margin check, and raise
   the call that asks the borrower for more collateral — end to end.
4. All state transitions are authorized — no participant can mutate collateral
   without the correct role.
5. The system runs locally on Anvil for development and can deploy to Base
   or Arbitrum testnets.
