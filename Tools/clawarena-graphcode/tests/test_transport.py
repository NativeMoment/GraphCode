import subprocess
from pathlib import Path

import pytest

from clawarena_graphcode.transport import GraphCodeCLI, TransportError, parse_node_id

STATUS = """clawarena  (running)
  7996AD03-A574-43E5-888D-4D1928D0D65C  running  goalBased  Summary Fixes
  1C2B51C0-472F-4F13-9650-A4666BE426D5  idle  timeBased  ClawArenaManager1a2b3c4d
"""


def test_parse_node_id_matches_whole_title():
    assert parse_node_id(STATUS, "ClawArenaManager1a2b3c4d") == "1C2B51C0-472F-4F13-9650-A4666BE426D5"
    assert parse_node_id(STATUS, "Summary Fixes") == "7996AD03-A574-43E5-888D-4D1928D0D65C"
    assert parse_node_id(STATUS, "Summary") is None


class FakeRunner:
    def __init__(self, status: str = "", fail: str | None = None):
        self.calls: list[list[str]] = []
        self.status = status
        self.fail = fail

    def __call__(self, argv, **kwargs):
        assert kwargs == {"capture_output": True, "text": True, "check": False}
        self.calls.append(argv)
        if self.fail and self.fail in argv:
            return subprocess.CompletedProcess(argv, 2, "", "daemon unreachable")
        if argv[1] == "node" and argv[2] == "create":
            title = argv[argv.index("--title") + 1]
            self.status = f"p  (running)\n  AAAA-1  running  timeBased  {title}\n"
        stdout = self.status if argv[1] == "status" else ""
        return subprocess.CompletedProcess(argv, 0, stdout, "")


def test_start_creates_an_uncadenced_time_loop_and_reads_its_id(tmp_path: Path):
    runner = FakeRunner()
    cli = GraphCodeCLI(tmp_path, executable="/opt/graphcode", backend="claudeCode", runner=runner)
    assert cli.start("be the manager") == "AAAA-1"
    create, status = runner.calls
    assert create[:4] == ["/opt/graphcode", "node", "create", str(tmp_path)]
    assert create[create.index("--type") + 1] == "time"
    assert create[create.index("--backend") + 1] == "claudeCode"
    assert create[-2:] == ["--prompt", "be the manager"]
    assert create[create.index("--title") + 1].startswith("ClawArenaManager")
    assert "--heartbeat" not in create
    assert status == ["/opt/graphcode", "status", str(tmp_path)]


def test_model_tier_is_passed_only_when_set(tmp_path: Path):
    runner = FakeRunner()
    GraphCodeCLI(tmp_path, model_tier="capable", runner=runner).start("p")
    create = runner.calls[0]
    assert create[create.index("--model") + 1] == "capable"

    runner = FakeRunner()
    GraphCodeCLI(tmp_path, runner=runner).start("p")
    assert "--model" not in runner.calls[0] and "--backend" not in runner.calls[0]


def test_deliver_and_stop(tmp_path: Path):
    runner = FakeRunner()
    cli = GraphCodeCLI(tmp_path, runner=runner)
    cli.deliver("AAAA-1", "ClawArena turn 2: read x")
    cli.stop("AAAA-1")
    assert runner.calls == [
        ["graphcode", "node", "send", str(tmp_path), "AAAA-1", "ClawArena turn 2: read x"],
        ["graphcode", "node", "stop", str(tmp_path), "AAAA-1"],
    ]


def test_failures_surface_stderr(tmp_path: Path):
    cli = GraphCodeCLI(tmp_path, runner=FakeRunner(fail="send"))
    with pytest.raises(TransportError, match="exited 2: daemon unreachable"):
        cli.deliver("AAAA-1", "hi")


def test_start_fails_when_the_loop_never_appears(tmp_path: Path):
    class Silent(FakeRunner):
        def __call__(self, argv, **kwargs):
            result = super().__call__(argv, **kwargs)
            if argv[1] == "status":
                return subprocess.CompletedProcess(argv, 0, "p  (running)\n", "")
            return result

    with pytest.raises(TransportError, match="missing from graphcode status"):
        GraphCodeCLI(tmp_path, runner=Silent()).start("prompt")
