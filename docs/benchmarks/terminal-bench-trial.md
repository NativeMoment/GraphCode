# Terminal-Bench trial: GraphCode goal loop vs. plain Claude Code

A private comparison, never submitted to a leaderboard. Question: on the same model, does
a GraphCode goal loop solve more Terminal-Bench tasks than Harbor's `claude-code` agent?

## Status: not run

| Prerequisite | State (2026-09-13) |
|---|---|
| Adapter (`Tools/harbor-graphcode`) | ✅ written, unit tests pass without Docker |
| Linux bundle recipe (`build-linux-bundle.sh`) | ⚠️ written, unverified |
| Container runtime (Docker or compatible) | ❌ not installed on the trial machine |
| `ANTHROPIC_API_KEY` | ❌ not set |

No tasks have been run, so there are no results below. Installing a container runtime and
providing a key is a human decision; this trial does not do either.

## Plan

| Step | Scope | Gate |
|---|---|---|
| 1. Build bundle | `ARCH=x86_64 Tools/harbor-graphcode/build-linux-bundle.sh` | Docker present |
| 2. Smoke | 2 tasks × 1 attempt, both agents | API key present |
| 3. Subset trial | 15 tasks × 1 attempt, both agents | Cost estimate approved |

- Dataset: `terminal-bench/terminal-bench-2` (pin the version at run time)
- Model: `anthropic/claude-opus-5` for both agents
- GraphCode arm runs with `done_check=agent`. `done_check=tests` hands the loop the
  verifier's own test, an oracle `claude-code` lacks, so it is reported only as a
  separate upper bound, never as the comparison.

## Cost estimate

Opus 5 list prices: $5 / MTok input, $25 / MTok output. Cache reads and writes are assumed
at the standard 0.1× and 1.25× input multipliers ($0.50 and $6.25 / MTok).

| Per task (assumed) | Tokens | Cost |
|---|---|---|
| Cache reads | 1.8M | $0.90 |
| Cache writes | 150K | $0.94 |
| Uncached input | 10K | $0.05 |
| Output | 40K | $1.00 |
| **`claude-code`** | | **≈ $3** |
| **GraphCode loop** (≈1.7× for re-wakes) | | **≈ $5** |

| Run | Trials | Estimate |
|---|---|---|
| Smoke | 2 tasks × 2 agents | ≈ $16 |
| Subset | 15 tasks × 2 agents | ≈ $120 |
| Subset + oracle arm | 15 tasks × 3 arms | ≈ $195 |

These are assumptions, good to roughly 2× either way. The smoke run's `harbor` token
counts replace them before the subset is approved.

## Results

| Task | `claude-code` | GraphCode (`agent`) | GraphCode (`tests`, oracle) |
|---|---|---|---|
| — | not run | not run | not run |

## Conclusion

None yet: nothing has been run, so this trial cannot say whether the goal loop helps.
