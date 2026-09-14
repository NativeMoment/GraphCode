"""How the provider reaches the manager loop."""

from __future__ import annotations

import subprocess
import uuid
from pathlib import Path
from typing import Callable, Protocol

LOOP_TITLE_PREFIX = "ClawArenaManager"


class TransportError(RuntimeError):
    pass


class Transport(Protocol):
    def start(self, prompt: str) -> str: ...

    def deliver(self, node_id: str, message: str) -> None: ...

    def stop(self, node_id: str) -> None: ...


def parse_node_id(status_output: str, title: str) -> str | None:
    """The id of the loop titled ``title`` in ``graphcode status`` output."""
    for line in status_output.splitlines():
        fields = line.split()
        if len(fields) >= 4 and " ".join(fields[3:]) == title:
            return fields[0]
    return None


def parse_node_state(status_output: str, node_id: str) -> str | None:
    for line in status_output.splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[0] == node_id:
            return fields[1]
    return None


Runner = Callable[..., subprocess.CompletedProcess]


class GraphCodeCLI:
    """Drives a loop through the ``graphcode`` CLI against a running graphcoded.

    The loop is time-based with no cadence: it starts at once, answers the turn its prompt
    points at, then sits idle until the next ``node send``. A goal loop would not do: on
    Claude Code a goal is a Stop hook that keeps the session working until the goal holds,
    which is the opposite of waiting for the harness.
    """

    def __init__(
        self,
        project: Path,
        *,
        executable: str = "graphcode",
        backend: str | None = None,
        model_tier: str | None = None,
        runner: Runner = subprocess.run,
    ):
        self.project = project
        self.executable = executable
        self.backend = backend
        self.model_tier = model_tier
        self._run = runner

    def start(self, prompt: str) -> str:
        title = f"{LOOP_TITLE_PREFIX}{uuid.uuid4().hex[:8]}"
        argv = ["node", "create", str(self.project), "--title", title, "--type", "time"]
        if self.backend:
            argv += ["--backend", self.backend]
        if self.model_tier:
            argv += ["--model", self.model_tier]
        self._call(argv + ["--prompt", prompt])
        status = self._call(["status", str(self.project)])
        node_id = parse_node_id(status, title)
        if node_id is None:
            raise TransportError(f"created loop {title} is missing from graphcode status")
        return node_id

    def deliver(self, node_id: str, message: str) -> None:
        self._call(["node", "send", str(self.project), node_id, message])

    def stop(self, node_id: str) -> None:
        self._call(["node", "stop", str(self.project), node_id])

    def state(self, node_id: str) -> str | None:
        return parse_node_state(self._call(["status", str(self.project)]), node_id)

    def _call(self, argv: list[str]) -> str:
        result = self._run(
            [self.executable, *argv], capture_output=True, text=True, check=False
        )
        if result.returncode != 0:
            raise TransportError(
                f"graphcode {' '.join(argv[:2])} exited {result.returncode}: "
                f"{(result.stderr or result.stdout).strip()[:500]}"
            )
        return result.stdout
