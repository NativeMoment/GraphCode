# clawarena-graphcode

Runs a GraphCode loop as the **main agent** (manager) of
[ClawArena-Team](https://github.com/aiming-lab/ClawArena/tree/main/ClawArena-Team), for private
trials. Nothing is added to ClawArena and nothing is submitted anywhere. The feasibility report,
the comparability caveats and the cost estimate are in
[`docs/benchmarks/clawarena-team-trial.md`](../../docs/benchmarks/clawarena-team-trial.md).

## How it plugs in

ClawArena scores management from its own tool traces. Every `Read`, `CreateSubagent`,
`RunSubagent` or `Workflow` has to go through its harness, so GraphCode joins as the `main`
*provider* rather than replacing the harness:

| Piece | Role |
|---|---|
| `GraphCodeProvider` (`provider: graphcode`) | Each harness model call becomes one turn file; the reply names tool calls or a final answer |
| Manager loop | A time loop with no cadence, created on the first call and woken by `graphcode node send` for later turns |
| `.claude/settings.json` in the loop's project | Denies Bash, Agent/Task, web tools, and reads or edits of the scenario workspace, so the loop can't work around the harness |
| `StubPoolProvider` (`provider: stub`) + scripted transport | Zero-spend dry run: no model is called anywhere |

The turn files are the whole protocol: `turn-NNNN.json` carries the messages the loop has not seen
and, when they change, the tool schemas; the loop writes `reply-NNNN.json` as
`{"content": "...", "tool_calls": [{"name": "...", "arguments": {...}}]}`. A malformed reply gets
one corrective turn, then a `ProviderError` (ClawArena retries the scenario).

## Install

The ClawArena-Team tokenizer ships in its checkout's `helper/`, so install it editable:

```sh
git clone https://github.com/aiming-lab/ClawArena   # trial pinned 630efd8a
cd ClawArena/ClawArena-Team
uv venv -p 3.12 .venv
uv pip install -p .venv/bin/python -e '.[dev]' -e /path/to/GraphCode/Tools/clawarena-graphcode
```

## Zero-spend dry run

A scripted manager answers through the real exchange files, and every pool key is a stub:

```sh
.venv/bin/clawarena-graphcode-dry-run -d data/clawarena-team -t s_observability_incident -o results/dry
```

It passes no rounds by construction. It shows that turns, reply parsing, harness-executed
subagent tools, per-round checks and the report all connect.

## Real run (not done: needs a subagent pool and approved spend)

```sh
.venv/bin/clawarena-graphcode run -d data/clawarena-team -t s_observability_incident \
  --config configs/eval_base.yaml -o results/graphcode \
  -m '{"main": {"provider": "graphcode", "model_id": "graphcode-claude-opus-5",
                "backend": "claudeCode", "model_tier": "capable",
                "turn_timeout_sec": 1800, "modalities": {"text": true}}}'
```

This needs a running graphcoded and a `graphcode` CLI on `PATH`, and the three pool endpoints
from `configs/eval_base.yaml` must answer. Each scenario creates one loop in its own throwaway
project directory, and loops are stopped when the process exits.

## Tests

```sh
.venv/bin/python -m pytest /path/to/GraphCode/Tools/clawarena-graphcode/tests
CLAWARENA_TEAM_DATA=$PWD/data/clawarena-team .venv/bin/python -m pytest /path/to/.../tests/test_dry_run.py
```
