# harbor-graphcode

A [Harbor](https://github.com/harbor-framework/harbor) installed agent that runs each
Terminal-Bench task as one GraphCode goal loop, for private trials against Harbor's plain
`claude-code` agent on the same model. It is loaded by import path; nothing is added to
Harbor itself, and nothing here submits to a leaderboard.

## How a task runs

1. **install** — installs zsh (graphcoded launches sessions through `/bin/zsh -i -l`),
   Claude Code via the inherited `ClaudeCode.install`, then uploads
   `graphcode-linux-<arch>.tar.gz` and unpacks `graphcode`, `graphcoded` and `zmx` into
   `/opt/graphcode/bin`.
2. **run** — starts graphcoded with `GRAPHCODE_SUPPORT_DIR=/tmp/gcd`, Claude permission
   mode `bypassPermissions` (`IS_SANDBOX=1`), and every model alias pinned to Harbor's
   `-m`. It creates one goal loop in the task's working directory with the instruction as
   its goal, then polls `graphcode status` until the loop is `succeeded`, `failed`,
   `stalled` or `stopped`.
3. **trajectory** — Claude Code transcripts are mirrored into
   `/logs/agent/sessions/projects`, where the inherited converter writes `trajectory.json`
   and token counts. `/logs/agent/graphcode/` keeps the daemon log, status snapshots and
   loop memory.

### Done check

| `done_check` | Loop predicate | Fair against `claude-code`? |
|---|---|---|
| `agent` (default) | None; the loop resolves when the session runs `graphcode node done` | ✅ The same information both agents get |
| `tests` (opt-in) | The task's own `tests/test.sh`, uploaded to `/tests` before the run; passes when it writes reward ≥ 1 | ❌ An oracle: the loop sees the verifier's verdict, plain `claude-code` does not. Only an upper bound. |

The tests directory is read from the trial's `config.json` (or the `tests_dir` kwarg).
Harbor empties `/tests` and re-uploads it before verification, and the check deletes the
reward it wrote, so verification itself is unaffected.

## Build the Linux bundle

Needs docker on the host; not verified yet (no container runtime on the machine this was
written on).

```sh
ARCH=x86_64 Tools/harbor-graphcode/build-linux-bundle.sh
```

Inside `swift:6.2` this runs `swift build -c release --static-swift-stdlib`, builds zmx at
the `ThirdParty/zmx` submodule pin (scgopi/zmx) with zig 0.15.2 `ReleaseFast`, and writes
`Tools/harbor-graphcode/dist/graphcode-linux-x86_64.tar.gz`. The binaries link glibc, so
Alpine task images are refused at install.

## Run

```sh
cd Tools/harbor-graphcode
uv sync
export ANTHROPIC_API_KEY=...            # never commit or echo it
export GRAPHCODE_LINUX_BUNDLE_DIR=$PWD/dist

# Smoke: 2 tasks x 1 attempt, both agents
uv run harbor run -d terminal-bench/terminal-bench-2 -e docker -m anthropic/claude-opus-5 \
  -a claude-code -l 2 -k 1
uv run harbor run -d terminal-bench/terminal-bench-2 -e docker -m anthropic/claude-opus-5 \
  -a harbor_graphcode:GraphCode -l 2 -k 1

# Oracle upper bound, reported separately, never as the comparison
uv run harbor run -d terminal-bench/terminal-bench-2 -e docker -m anthropic/claude-opus-5 \
  -a harbor_graphcode:GraphCode --ak done_check=tests -l 2 -k 1
```

Check `harbor run --help` for the task-selection flag your Harbor version uses before
spending. Useful kwargs: `done_check=tests|agent`, `budget_tokens=<n>`,
`poll_interval_sec=<n>`, `bundle_dir=<path>`.

## Tests

No Docker or API key needed:

```sh
uv run --group dev pytest
```

## What is verified

| Piece | Status |
|---|---|
| Adapter logic, generated shell (`bash -n`), awk/Python parser agreement, oracle reward check | ✅ unit tests |
| `graphcode status` line format and a loop reaching `stopped` | ✅ against a real macOS graphcoded (see PR) |
| Linux bundle build in `swift:6.2` | ⚠️ unverified, no container runtime |
| graphcoded launching a Claude session on Linux inside a task image | ⚠️ unverified; CI only smoke-tests CLI verbs on Linux |
| Claude Code's first-run prompts suppressed by the seeded `~/.claude.json` | ⚠️ unverified |
