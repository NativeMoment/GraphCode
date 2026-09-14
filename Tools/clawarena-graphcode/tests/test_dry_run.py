"""The zero-spend dry run against a real ClawArena-Team dataset.

Set ``CLAWARENA_TEAM_DATA`` to ``<ClawArena-Team checkout>/data/clawarena-team`` to run it;
it needs the checkout's bundled tokenizer, so clawarena-team must be installed editable.
"""

import json
import os
from pathlib import Path

import pytest

from clawarena_graphcode.cli import dry_run

DATA = os.environ.get("CLAWARENA_TEAM_DATA")
SCENARIO = "s_observability_incident"


@pytest.mark.skipif(not DATA, reason="CLAWARENA_TEAM_DATA is not set")
def test_scripted_manager_runs_a_scenario_end_to_end(tmp_path: Path):
    with pytest.raises(SystemExit) as exit_info:
        dry_run(["-d", DATA, "-t", SCENARIO, "-o", str(tmp_path / "out"),
                 "--exchange-root", str(tmp_path / "exchange")])
    assert exit_info.value.code in (0, None)

    (scenario_dir,) = (tmp_path / "out").glob(f"*/{SCENARIO}")
    metadata = json.loads((scenario_dir / "metadata.json").read_text())
    assert metadata["models"]["main"]["provider"] == "graphcode"
    assert len(metadata["rounds"]) == len(list((scenario_dir / "evals").glob("*.json"))) > 0
    assert metadata["metrics"]["subagent_create_count"] >= 1

    called = set()
    for line in (scenario_dir / "sessions" / "main.jsonl").read_text().splitlines():
        called.update(call["name"] for call in json.loads(line).get("tool_calls") or [])
    assert {"CreateSubagent", "RunSubagent"} <= called

    (exchange,) = (tmp_path / "exchange").glob("exchange-*")
    turns = sorted(exchange.glob("turn-*.json"))
    assert turns and len(turns) == len(list(exchange.glob("reply-*.json")))
