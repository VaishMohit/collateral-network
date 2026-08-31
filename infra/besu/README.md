# Besu QBFT Devnet (infra/besu)

A 3-validator Hyperledger Besu **permissioned-style** devnet running locally
via Docker Compose. QBFT Proof-of-Authority consensus, one validator per
"participating bank", full-mesh peering via static nodes.

## Quick start

```bash
# start Docker Desktop first, then:
docker compose up -d
```

Verify it is mining and peered:

```bash
cast block-number --rpc-url http://127.0.0.1:8545   # block number, climbing
cast chain-id --rpc-url http://127.0.0.1:8545        # 1337
cast rpc qbft_getValidatorsByBlockNumber latest --rpc-url http://127.0.0.1:8545
cast rpc admin_peers --rpc-url http://127.0.0.1:8550 # full mesh: 2 peers
```

Stop / reset:

```bash
docker compose down
# to start from a clean chain, also wipe the data dirs:
rm -rf data/node1 data/node2 data/node3 && mkdir -p data/node1 data/node2 data/node3
```

## Nodes + ports

| Node | RPC (host) | WS | P2P | IP (docker net) | Role |
|------|-----------|----|-----|------------------|------|
| validator1 | `http://127.0.0.1:8545` | 8546 | 30303 | 172.28.0.11 | bank validator + anchor |
| validator2 | `http://127.0.0.1:8550` | — | 30303 | 172.28.0.12 | bank validator |
| validator3 | `http://127.0.0.1:8551` | — | 30303 | 172.28.0.13 | bank validator |

`cast`/`forge` interact with any node over JSON-RPC exactly like Anvil.

## Consensus: QBFT

- Proof-of-Authority; no PoW, no staking. Validators propose + commit blocks.
- Block time **2 s** (`blockperiodseconds`); needs `2f+1` of 3 = **2 validators
  to commit** each block (tolerates 1 faulty validator).
- Genesis `extraData` is the RLP-encoded list of the 3 initial validators
  (regenerate with `besu rlp encode --from=validators.json --type=QBFT_EXTRA_DATA`).

## Peering: full mesh via static nodes

Each validator has a `static-nodes/validatorX.json` file listing the *other
two* validators. Static peers are **maintained connections** — not
discovery-driven — so every pair (1↔2, 2↔3, 1↔3) is always directly
connected. This matters for QBFT, where every validator broadcasts
PREPARE/COMMIT votes to all validators; a star-through-one-node would make a
single node a central relay.

The enode node-IDs are derived from `keys/validatorX.key` (node public keys
are logged at startup: `Loaded public key 0x...`).

## Genesis funding

The three validator addresses are pre-funded in `genesis.json` `alloc`.
For protocol deployment, the Anvil development accounts used by
`script/Deploy.s.sol` (e.g. `0xf39f...`, `0x7099...`) were funded 5 ETH each
from validator1 — see the Phase 5 deployment script instead of hand-funding.

## Notes / open items

- **Account permissioning** (`--permissions-accounts-config-file-enabled`) is
  intentionally NOT enabled: it currently fails to start with
  `ERROR_ALLOWLIST_PERSIST_FAIL`. Layering network-level account
  allowlisting on top of the QBFT chain is an open Phase 5 task.
- This is a private devnet (fixed validator set, fixed IPs, single host). It is
  not a public network and not production.
- Existing Besu v26 removed legacy `--miner-enabled` / `--miner-coinbase`;
  QBFT validators produce blocks from their node keys automatically.
