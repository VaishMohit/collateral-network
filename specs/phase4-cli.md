# Phase 4 — CLI: Margin Monitor

The `margin-monitor` CLI drives the two-actor margin workflow against a local
Anvil devnet. It exposes the single "price update then evaluation" loop
(Option A): a **Valuation Provider** pushes a price, and a **Collateral Agent**
explicitly evaluates and raises the call.

## Roles and commands

Two distinct roles, two distinct signer keys. Kept separate so the data
provider can later be swapped for a Chainlink feed and the operator for a
Chainlink keeper without changing the command surface.

| Role | Anvil key (`script/LibConstants.sol`) | CLI command | On-chain call |
|------|----------------------------------------|-------------|---------------|
| **VALUATION_PROVIDER** | `PK_VALUATION_PROVIDER` | `price update` | `ValuationOracle.updatePrice` (signed) |
| **COLLATERAL_AGENT** | `PK_COLLATERAL_AGENT` | `check` | `MarginManager.evaluateMargin` / `evaluateAll` |
| COLLATERAL_AGENT | `PK_COLLATERAL_AGENT` | `watch` | repeated `check` poll loop |
| — (read-only) | none | `status` | `MarginManager.getMarginStatus` |
| — (read-only) | none | `history` | `MarginManager.getMarginCallHistory` |

`price update` only writes a price into the oracle. It never evaluates or
raises a call. `check` / `watch` only read prices and evaluate — they never
set a price. Nothing on-chain links the two; the operator drives the sequence.

## Commands

```
margin-monitor deploy                                   # bootstrap network on Anvil
margin-monitor price update <asset> <priceCents>        # provider: push a price
margin-monitor check [<obligationId>]                   # agent: evaluate; raise call on shortfall
margin-monitor watch [--interval <ms>]                  # agent: poll loop (default 5000ms)
margin-monitor status <obligationId>                    # read margin call status
margin-monitor history <obligationId>                   # read ring-buffer history
```

Arguments:
- `<asset>` — asset id, e.g. `T_BOND`.
- `<priceCents>` — price in USD cents, e.g. `9200` = $92.00.
- `<obligationId>` — repo/obligation id as hex, e.g. the deterministic
  `keccak256("REPO",1,A,B)` used by `Deploy`/`Demo`.

## Keys

Keys are read from `.env` at the repo root, overridable per command:

| Env var | Used by |
|---------|---------|
| `VALUATION_PROVIDER_KEY` | `price update`, `deploy` (adds price) |
| `COLLATERAL_AGENT_KEY` | `check`, `watch` |
| `RPC_URL` | all (default `http://127.0.0.1:8545`) |

Per-command override:

```
margin-monitor --provider-key 0x<key> price update T_BOND 9200
margin-monitor --operator-key 0x<key> check
```

`status` / `history` need no key — read-only over the RPC.

## Deployment discovery

`deploy` writes contract addresses to `deployments/anvil.json`, reusing the
layout produced by `script/Deploy.s.sol`. All other commands read that file to
resolve `ValuationOracle`, `MarginManager`, and the participant addresses. This
keeps the CLI aligned with the existing Foundry deploy/demo flow.

## Example flow (Option A)

```
$ margin-monitor deploy
# ... network live, obligation repoId = keccak256("REPO",1,A,B)

$ margin-monitor price update T_BOND 10000        # provider: $100.00
$ margin-monitor check 0x<repoId>                 # agent: adequate -> no call
$ margin-monitor status 0x<repoId>                # no active call

$ margin-monitor price update T_BOND 9200         # provider: price falls to $92.00
$ margin-monitor check 0x<repoId>                 # agent: shortfall $26,000 -> raises call
$ margin-monitor status 0x<repoId>                # active call, collateral $874,000 < required
$ margin-monitor history 0x<repoId>               # shows the raised-call record
```

Result: the **system asks for more collateral** — an active `MarginCall` is
created on the obligation, visible via `status`/`history` and recorded in the
audit log.

## On-chain dependencies

Phase 4 adds to `MarginManager`:
- `MarginEvaluation` struct + `evaluateMargin(obligationId)` view (no revert on
  adequate).
- `previewMarginCall(obligationId)` view.
- `evaluateAll(obligationIds[])` — raises a call for any obligation with a
  shortfall; gated by `onlyBankOrAgent` (COLLATERAL_AGENT or BANK).
- Bounded ring-buffer history (last 16) + `getMarginCallHistory` / paginated
  view, written by create/satisfy/cancel.

## Acceptance (CLI)

- `price update T_BOND <price>` writes a signed price readable back from the
  oracle.
- `check` on an adequate obligation reports adequate and raises no call.
- After a price drop, `check` raises a margin call (active = true, shortfall >
  0) on the obligation.
- `status` reflects the raised call; `history` contains the record.
- `watch` raises the call automatically once the price crosses the shortfall
  threshold, without manual `check`.
- `price update` never raises a call on its own (Option A).
