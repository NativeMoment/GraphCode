# ClawArena-Team trial: GraphCode as the manager

**Verdict:** ⚠️ Feasible as a *private, disclosed-deviation* trial. It cannot enter the leaderboard as
a like-for-like row. The adapter and a zero-spend dry run are done. A real run is blocked on a
subagent pool (no NVIDIA GPU here) and on approved main-agent spend.

- Benchmark: [aiming-lab/ClawArena](https://github.com/aiming-lab/ClawArena), `ClawArena-Team/`, MIT,
  pinned at `630efd8a` (2026-07-01)
- Adapter: [`Tools/clawarena-graphcode`](../../Tools/clawarena-graphcode)
- Nothing was submitted, posted, installed system-wide, or billed.

## 1. What ClawArena-Team measures

A text-only main agent completes 41 multi-round scenarios (258 rounds) that it can only finish by
delegating to a fixed pool: `llm` and `vlm` are gemma-4-31b-it, `omni` is gemma-4-e4b-it, all on
local vLLM. Scoring is execution-based. The headline is `SMS = TCR × (TPP + ROC + WPP + MCA) / 4`:
task correctness discounted by least-privilege and modality-routing quality. The leaderboard ranks
**main-agent models**. Harness, prompts, tools and pool are held fixed.

## 2. How a GraphCode lead loop maps onto the manager

The management metrics (TPP, ROC, WPP, MCA) are computed from the harness's own records of
`CreateSubagent` / `RunSubagent` / `Workflow` calls, and the round checks read
`${workspace}/sessions/main.jsonl`. Anything done outside the harness is invisible to scoring or
counts as a violation. So GraphCode cannot use its own graph machinery here. It joins as the
`main` **provider**:

| ClawArena manager concept | Native GraphCode equivalent | What the adapter does |
|---|---|---|
| Main agent model call | One loop turn | Each `chat()` writes `turn-NNNN.json`; the loop replies with `reply-NNNN.json` |
| `CreateSubagent` (prompt, model key, tools, path whitelist) | `graphcode node create` a child loop | Harness tool call. A child loop would run on Claude/Codex, not the fixed gemma pool |
| `RunSubagent` foreground/background, resume | `node send` / handoff edge / session resume | Harness tool call |
| `<task-notification>` on background completion | Mailroom / message edge delivery | Arrives inside the next turn file |
| `Workflow` (`agent()`, `parallel()`, `pipeline()`) | Workflow scripts / composite loops | Harness tool call |
| Least-privilege grants, realpath sandbox | Claude Code permissions per loop | The harness enforces; the loop's own project denies Bash, Agent/Task, web tools and workspace reads/edits |
| Text-only perception | — | Multimodal parts reach the loop only as placeholders |

The loop is a **time loop with no cadence**. On Claude Code a goal loop is a `/goal` Stop hook
that keeps the session working until the goal holds, which is the opposite of idling between
harness turns. A time loop starts at once, answers the turn its prompt points at, and sleeps
until the next `graphcode node send`. Content travels in files because `node send` flattens
newlines and clips long messages.

**What this trial measures:** the manager judgement of a model *running inside a GraphCode loop*
(Claude Code system prompt, GraphCode briefing, memory), against the same model called directly.
**What it does not measure:** GraphCode's fan-out into child loops, edges or the Mailroom. Using
those would bypass the fixed pool and the scoring, so they are out of scope.

## 3. Leaderboard comparability

| Question | Answer | Why |
|---|---|---|
| Is a GraphCode run a leaderboard row? | ❌ No — disclosed deviation | Rows are main-agent models under the stock harness; this is a scaffold (Claude Code + loop) around a model |
| Are the management metrics still valid? | ✅ Yes | Every tool call is still executed, sandboxed and scored by ClawArena |
| Is TCR still valid? | ✅ Yes | Same checks, same workspace |
| Is the Cost column comparable? | ❌ No | The harness counts tokens on its own history with a local tokenizer; the loop's real spend (Claude Code system prompt, file reads/writes, thinking) must come from Claude Code usage instead |
| Residual bypass risk | ⚠️ Mitigated, not proven | Per-loop deny rules plus the prompt; not yet verified against a live session. Auditing the loop transcript for any tool use outside the exchange directory should be part of a real run |
| Meaningful result | Paired comparison | `graphcode(claude-opus-5)` vs `anthropic(claude-opus-5)` on the same pool and scenarios |

## 4. Serving the pool without an NVIDIA GPU

The pool config (`configs/eval_base.yaml`) points `llm`/`vlm` at gemma-4-31b-it and `omni` at
gemma-4-e4b-it, both served by vLLM nightly with `--tool-call-parser gemma4
--reasoning-parser gemma4`, MTP speculative decoding (31B), fp8 KV cache, `max-model-len 128000`,
and `--limit-mm-per-prompt` image=48/video=8 (31B) and audio=4/image=24/video=4 (E4B). This Mac is
an Apple M4 with 16 GB, which cannot hold the 31B model. vLLM, CUDA and Docker are out of bounds
anyway.

| Option | `llm`/`vlm` (31B) | `omni` (E4B, audio) | Comparability |
|---|---|---|---|
| OpenRouter, OpenAI-compatible (`provider: openai_compat`) | `google/gemma-4-31b-it` listed at about $0.09–0.14 / $0.34 per MTok in/out, plus a rate-limited `:free` variant | ⚠️ Not confirmed. One source says E4B is on no hosted provider; another lists 3 providers at $0.02 / $0.10 | ⚠️ Deviation: provider quantization, chat template, tool-call parsing, context and multimodal limits all differ from the vLLM recipe |
| Google Gemini API (hosts Gemma) | `gemma-4-31b-it` documented, $0 on a rate-limited free tier | ❌ E4B not listed (only 31b and 26b-a4b) | ⚠️ Same deviation. ClawArena's probe posts OpenAI-style `/chat/completions`, so it needs Google's OpenAI-compatible endpoint (unverified for Gemma). Free-tier rate limits vs ~9k pool calls per full run make it days-long |
| Substitute `omni` with a non-E4B model | — | Audio rounds routed elsewhere | ❌ Breaks MCA and the audio rounds; only as a labelled ablation |
| Rent GPUs and run the published vLLM recipe | 1× ~96 GB GPU per replica | 1 small GPU | ✅ Closest to reference. Needs a cloud/GPU account — a human decision, not taken |

**Hosted-pool verdict:** usable for a private paired comparison, provided **both arms use the same
hosted pool**. The paired result stays internally valid, but no absolute number can be set beside
the leaderboard. A calibration arm fixes that: rerun a model that already has a submission
(`local-gemma-31b`: SMS 43.86, 146/258) on the hosted pool over a few scenarios, and report the
drift.

## 5. What was verified (zero spend)

| Check | Result |
|---|---|
| Adapter unit tests: protocol, CLI transport argv/parsing, provider turn/retry/timeout/liveness/stop, scripted manager | ✅ 30 passed |
| Upstream ClawArena-Team unit tests in the same venv | ✅ 320 passed, 8 skipped |
| Dry run, `s_observability_incident` (7 rounds), scripted manager through real exchange files, stub pool | ✅ Scenario completed; metadata, per-round evals and report written |
| — manager tool calls executed by the harness | 1 `CreateSubagent`, 7 `RunSubagent`; 15 turn/reply pairs; 7 stub subagent sessions |
| — scores | 0/7 rounds, SMS 0, as designed: no model runs, so no output files. ROC 1.0, MCA 1.0 |
| Dataset-gated dry-run test (`CLAWARENA_TEAM_DATA`) | ✅ passed |
| `GraphCodeCLI` against a real graphcoded (shipped 0.1.70 binaries copied to `/tmp`, isolated support dir, daemon env scrubbed so `claude` is not found: zero spend) | ✅ `node create --type time --backend claudeCode --model capable --prompt …` accepted, the project auto-registered, and the id was parsed from `graphcode status`. The loop went `stopped: claude is not on your PATH`, as intended |
| — `node send` to that stopped loop | Exits 1 ("isn't live right now — message staged to its memory"). The provider now also polls loop state and fails the call once the loop is `stopped`/`failed`/`stalled`/`succeeded`, instead of waiting out the 30-minute turn timeout |
| A real manager (Claude Code in a loop) answering turns | ❌ Not run: spend |

Reproduce:

```sh
cd ClawArena/ClawArena-Team   # editable installs per the adapter README
.venv/bin/clawarena-graphcode-dry-run -d data/clawarena-team -t s_observability_incident -o results/dry
```

## 6. Cost estimate

Assumption-heavy; treat every figure as ±2×. Pricing: Claude Opus 5 at $5 / $25 per MTok in/out,
cache reads assumed at 0.1× ($0.50) and cache writes at 1.25× ($6.25); Claude Sonnet 5 at $2 / $10.
Token volumes come from the two full-run submissions in the repo:

| Full 41-scenario run | Main new input | Main output | Main cache-read | Pool new input | Pool history | Pool output |
|---|--:|--:|--:|--:|--:|--:|
| `local-gemma-31b` | 0.91M | 0.44M | 35.8M | 5.69M | 31.5M | 0.51M |
| `local-qwen3.6-27b` | 1.16M | 0.65M | 45.5M | 5.07M | 26.6M | 0.71M |

Main-agent calls run at roughly 50–60 per scenario (cache-read ÷ average context).

### Main agent (API)

| Arm | 1 scenario (smoke) | Full 41 scenarios | Basis |
|---|--:|--:|---|
| Control: `anthropic` provider, claude-opus-5 | ≈ $1–2 | ≈ $40–70 | ~1M new input, ~40M cache read, ~0.55M output; leaderboard `claude-sonnet-4-6` cost $39.7 at $3/$15 |
| GraphCode loop, claude-opus-5 | ≈ $3–13 (central $6) | ≈ $130–540 (central $270) | Each harness turn costs ~2–3 session calls (read turn, write reply); ~25K fixed Claude Code + briefing prefix; turn content re-appears as file reads and reply writes |
| GraphCode loop, claude-sonnet-5 | ≈ $1–5 | ≈ $55–220 | Same volumes at $2/$10 |

If the loops run on a Claude subscription rather than an API key, the marginal charge is plan
usage and rate limits, not dollars. The dollar column is the API-equivalent either way.

### Subagent pool hosting

Pool volume is ~32–37M input and ~0.5–0.7M output tokens per full run. A stronger manager may
delegate more, so allow up to 2×.

| Pool option | 1 scenario | Full 41 scenarios | Caveat |
|---|--:|--:|---|
| OpenRouter gemma-4-31b-it (no cache discount assumed) | ≈ $0.15–0.30 | ≈ $5–11 | E4B `omni` hosting unconfirmed |
| Gemini API free tier (31B only) | $0 | $0 | Rate limits; no E4B; OpenAI-compatible Gemma endpoint unverified |
| Rented GPUs running the reference vLLM recipe | ≈ $5–15 | ≈ $30–200 | Assumes $2–4 per GPU-hour, 2 GPUs, 8–24 h wall clock; needs a GPU account |

**A paired run (control + GraphCode) with a hosted pool:** smoke ≈ **$5–15**, full ≈ **$180–630**,
almost all of it main-agent API.

## 7. Blockers and decisions for a human

1. **Pool:** choose OpenRouter (an account and key), a GPU rental, or stop here. No option is
   available without a new account.
2. **Omni:** confirm a hosted gemma-4-e4b-it with audio input, or accept an ablation that drops or
   reroutes audio rounds.
3. **Spend:** approve a 1-scenario paired smoke (≈ $5–15) before anything larger.
4. **Before the smoke:** check the manager loop live, zero-spend where possible. Confirm the deny
   rules actually block workspace reads in a `bypassPermissions` session, and that a time loop with
   no cadence stays idle between `node send` wake-ups.
5. **Submission:** none planned. If one were ever made, it would be labelled as a scaffold entry
   with the deviations above.
