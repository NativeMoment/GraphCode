"""``clawarena-graphcode``: the ClawArena-Team CLI with the graphcode providers registered."""

from __future__ import annotations

import argparse
import json
import sys

from . import register, stop_all

STUB_POOL = {
    "llm": {"provider": "stub", "model_id": "stub-llm", "modalities": {"text": True}},
    "vlm": {
        "provider": "stub",
        "model_id": "stub-vlm",
        "modalities": {"text": True, "image": 8, "video": 2},
    },
    "omni": {
        "provider": "stub",
        "model_id": "stub-omni",
        "modalities": {"text": True, "image": 8, "audio": 4, "video": 2},
    },
}


def dry_run_model_json(exchange_root: str | None = None) -> str:
    main = {
        "provider": "graphcode",
        "model_id": "graphcode-scripted-dry-run",
        "transport": "scripted",
        "poll_interval_sec": 0.05,
        "turn_timeout_sec": 30,
        "modalities": {"text": True},
    }
    if exchange_root:
        main["exchange_root"] = exchange_root
    return json.dumps({"main": main, **STUB_POOL})


def main(argv: list[str] | None = None) -> None:
    register()
    from clawarena_team.cli import main as clawarena_main

    try:
        clawarena_main.main(args=argv, prog_name="clawarena-graphcode")
    finally:
        stop_all()


def dry_run(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="clawarena-graphcode-dry-run",
        description="Run scenarios with a scripted manager and a stub pool: no model, no spend.",
    )
    parser.add_argument("-d", "--data", required=True)
    parser.add_argument("-t", "--scenario-id", required=True)
    parser.add_argument("-o", "--out", required=True)
    parser.add_argument("--exchange-root")
    args = parser.parse_args(argv if argv is not None else sys.argv[1:])
    main(
        [
            "run",
            "-d", args.data,
            "-t", args.scenario_id,
            "-o", args.out,
            "--retry", "1",
            # The probe posts real HTTP requests to each pool api_base; the stubs have none.
            "--skip-probe",
            "-m", dry_run_model_json(args.exchange_root),
        ]
    )
