# Plan — Phase 3: Invariant & fuzz test suite

## Task Group 1: Shared handler infrastructure

**Files:** `test/invariant/BaseHandler.sol`

1. Create `BaseHandler` as an abstract contract extending `TestBase`; call
   `_deployNetwork()` plus the `_setupBankAReady`-style scenario helpers in
   its setup path so the network starts in a pledge-ready state.
2. Add a bounded actor set (bankA, bankB, collateralAgent, settlementAgent)
   with a `currentActor` index pattern (`bound(seed, 0, actors.length - 1)`)
   so `vm.prank` targets vary across runs.
3. Implement weighted handler actions, each with an internal precondition
   check that returns early instead of reverting (required because
   `fail_on_revert = true`):
   - `pledge(assetIdIdx, quantity, actorSeed)` — wraps the full
     requestPledge → verifyCollateral → reserveCollateral → approvePledge →
     finalizePledge flow via TestBase helpers
   - `release(positionId)` — release path for a tracked position
   - `substitute(positionId, newAssetIdIdx, newQuantity)`
   - `createRepo / settleRepo / repayAndClose(positionId)` — repo lifecycle
   - `defaultRepo(repoId)` — enforcement path
   - `updatePrice(assetIdIdx, priceDeltaBps)` — signed oracle refresh
   - `renewAttestation(assetIdIdx)` — keeps eligibility alive mid-sequence
4. Maintain ghost state used by all invariant suites:
   - `positionIds[]` + per-position ghost record (assetId, provider,
     quantity, expectedStatus, exists flag)
   - `custodyKeys[]` — every `(assetId, owner)` pair touched
5. Expose getters the invariant contracts read: positions touched this run,
   ghost status map, custody keys touched.

## Task Group 2: Accounting invariant (step 3.1)

**Files:** `test/invariant/AccountingInvariant.t.sol`

1. Contract inherits `BaseHandler`; declares `invariant_TotalEqualsBreakdown()`.
2. Invariant assertion: for every provider/asset pair touched by the handler,
   the tokenized balance held against the CollateralManager equals
   reserved + pledged quantities of live positions + available quantity.
3. Per-position check: each tracked position's on-chain status and quantity
   match the ghost record exactly.
4. Cash-side conservation during repo/settlement actions: cash paid by
   receiver == principal + interest credited to provider for settled repos
   (ghost-tracked in the handler).
5. Run config: rely on `[invariant]` from `foundry.toml`
   (256 runs × depth 128).

## Task Group 3: Custody invariant (step 3.2)

**Files:** `test/invariant/CustodyInvariant.t.sol`

1. Contract inherits `BaseHandler`; declares `invariant_EncumbranceBounded()`.
2. Invariant assertion: for every `(assetId, owner)` key the handler touched,
   `CustodyRegistry.encumberedQuantity <= totalQuantity` — read both fields
   from the registry directly.
3. Consistency assertion: `availableQuantity(assetId, owner)` ==
   `totalQuantity - encumberedQuantity` for those keys (guards the derived-
   value helper drifting from stored state).
4. Multi-owner regression pressure: ensure the actor pool attests overlapping
   assets from two different banks so the `(assetId, owner)` keying from
   Phase 1 is exercised under random interleavings.

## Task Group 4: State machine invariant (step 3.3)

**Files:** `test/invariant/StateMachineInvariant.t.sol`

1. Define the legal edge set in the test:
   AVAILABLE → RESERVED; RESERVED → PLEDGED; RESERVED → AVAILABLE
   (cancel); PLEDGED → RELEASE_REQUESTED; RELEASE_REQUESTED → RELEASED;
   PLEDGED/RESERVED → DEFAULTED; DEFAULTED → RECOVERY. Terminal states have
   no outgoing edges except where the contract explicitly allows.
2. Handler wrapper `moveStatus(positionId, action)` records
   `statusBefore[positionId] = currentGhostStatus` before each state-mutating
   call and updates the ghost after success.
3. Invariant assertion: for every tracked position,
   `(lastStatus, onChainStatus)` is always a member of the legal edge set.
4. Terminal-state assertion: once a position reaches RELEASED or RECOVERY in
   ghost state, its on-chain status never changes again.

## Task Group 5: Fuzz createPosition (step 3.4)

**Files:** `test/fuzz/CreatePositionFuzz.t.sol`

1. Standard fuzz contract extending `TestBase` (fresh deployment per run).
2. `testFuzz_createPosition_ValidInputs(uint256 quantitySeed, uint8 assetSel,
   uint8 providerSel)`: `bound()` quantities to `[1, attestedQuantity]`,
   select among registered asset/provider pairs; assert position created with
   exact quantity/status/provider and custody encumbrance incremented by
   exactly `quantity`.
3. `testFuzz_createPosition_InvalidInputs(...)`: zero quantity, unregistered
   asset ID, unattested provider — expect the specific custom error each time.
4. Boundary probes inside valid-input fuzz: max uint256-safe quantity bounds,
   quantity equal to full attested amount (drains available to zero).

## Task Group 6: Fuzz repayAndClose (step 3.5)

**Files:** `test/fuzz/RepayCloseFuzz.t.sol`

1. Deterministic setUp: pledge + repo creation at fuzzable parameters.
2. `testFuzz_repayAndClose_Math(uint64 principalSeed, uint16 rateBpsSeed,
   uint32 tenorSecondsSeed)`: bound to sane ranges (principal ≤ minted cash,
   rate ≤ 100%, tenor ≥ 0); assert returned `repaid` equals
   principal + simple interest computed with the same day-count convention
   as `RepoManager`, and that receiver's cash debit equals provider's credit
   to the wei.
3. `testFuzz_repayAndClose_Reverts(uint256 warpSeed)`: repay before settle,
   double repay, repay by non-party, repay past default — expect specific
   custom errors.
4. Overflow probe: maximum-rate × maximum-tenor combination stays within
   uint256 without revert or truncation.

## Task Group 7: Gas benchmarks & documentation (step 3.6)

**Files:** `test/bench/GasBenchmarks.t.sol`, `docs/gas.md`

1. Benchmark contract extending `TestBase`; one test per critical path,
   measured as `gasleft()` deltas around the operation, results logged with
   `console2.log`:
   - full pledge flow (request → finalize)
   - DvP settlement
   - collateral substitution
   - margin call creation
   - `repayAndClose`
2. Transcribe measurements into `docs/gas.md` as a table: operation, gas,
   notes (block/gas version), dated.
3. No CI gate: benchmarks are documentation only this phase (decision 3).
