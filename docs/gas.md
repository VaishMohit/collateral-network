# Gas Benchmarks

Measured with `test/bench/GasBenchmarks.t.sol` (gasleft deltas, in-memory
Anvil network, solc 0.8.24 / cancun, optimizer 200 runs). Machine-dependent —
reference numbers only, no CI gate (see Phase 3 spec decision 3).

Reproduce: `forge test --match-contract GasBenchmarks -vvvv`
(events `BenchResult(label, gas)` carry the measured delta).

| Operation | Gas | Notes |
|-----------|-----|-------|
| Pledge flow (request → verify → reserve → approve → finalize) | 1,459,269 | Five transactions incl. eligibility + compliance + valuation checks and token lock |
| DvP settlement (`settleRepo`, cash leg) | 473,568 | Single atomic transaction |
| Substitution activate (release old + pledge replacement) | 523,522 | Final step only; request/validate/reserve precede it |
| Margin call creation (live valuation over obligation) | 378,347 | Includes mark-to-market over all encumbered positions |
| `repayAndClose` (interest calc + collateral release) | 495,089 | Excludes the borrower approval tx |

Date: 2026-08-24

## Caveats

- The pledge-flow figure spans five separate calls; per-call cost is roughly
  a fifth of the total.
- Values scale with position count per obligation for margin evaluation
  (linear scan of `positionsByObligation`, capped at 64).
- Benchmarked quantities: T-BOND 1,000–10,000 units; repo $950k at 5% / 7d.
