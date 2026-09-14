"""Zero-spend stand-ins: a scripted manager behind the real exchange, and a stub pool.

Neither calls a model. A dry run with them proves the plumbing — turn files, reply
parsing, the harness executing CreateSubagent/RunSubagent, per-round checks and the
report — and nothing about how well any model manages.
"""

from __future__ import annotations

import json
import re
from typing import Any

from clawarena_team.provider.base import BaseProvider

from .protocol import Exchange, delegable_paths

_SUBAGENT_ID_RE = re.compile(r"subagent_id=(\S+)")


class StubPoolProvider(BaseProvider):
    name = "stub"

    async def chat(self, *, messages, tools=None, **kwargs):
        return self.normalise_response(
            content=f"[stub {self.config.model_id}] no model was called ({len(messages)} messages)"
        )


class ScriptedManager:
    """Per user question: create one llm subagent over the first delegable path (once),
    run it on the question, then answer with what it returned."""

    def __init__(self) -> None:
        self.subagent_id: str | None = None
        self.delegable: list[str] = []
        self.question = ""
        self.phase = "idle"

    def answer(self, turn: dict[str, Any]) -> dict[str, Any]:
        messages = turn.get("messages") or []
        self.delegable = self.delegable or delegable_paths(messages)
        for message in messages:
            if message.get("role") == "user" and message.get("content", "").strip():
                self.question = message["content"].split("<system-reminder>")[0].strip()
                self.phase = "question"
        tool_output = "\n".join(m.get("content", "") for m in messages if m.get("role") == "tool")

        if self.phase == "question":
            if not self.delegable:
                return self._final("no delegable paths; answered without subagents")
            if self.subagent_id is None:
                self.phase = "creating"
                return self._call(
                    "CreateSubagent",
                    name="dry-run-reader",
                    system_prompt="Answer from the files you were granted.",
                    model_key="llm",
                    tools=["Read", "Grep", "Glob"],
                    accessible_paths=self.delegable[:1],
                )
            return self._run()
        if self.phase == "creating":
            match = _SUBAGENT_ID_RE.search(tool_output)
            if match is None:
                return self._final(f"CreateSubagent failed: {tool_output[:200]}")
            self.subagent_id = match.group(1).rstrip(",.")
            return self._run()
        if self.phase == "running":
            return self._final(f"dry run: subagent {self.subagent_id} returned: {tool_output[:200]}")
        return self._final("nothing pending")

    def _run(self) -> dict[str, Any]:
        self.phase = "running"
        return self._call(
            "RunSubagent",
            subagent_id=self.subagent_id,
            description="dry-run delegation",
            prompt=self.question[:2000] or "Summarise your files.",
        )

    def _final(self, text: str) -> dict[str, Any]:
        self.phase = "idle"
        return {"content": text, "tool_calls": []}

    @staticmethod
    def _call(name: str, **arguments: Any) -> dict[str, Any]:
        return {"content": "", "tool_calls": [{"name": name, "arguments": arguments}]}


class ScriptedTransport:
    """Answers each turn file the moment it is delivered, through the same files a loop uses."""

    def __init__(self, exchange: Exchange, manager: ScriptedManager | None = None):
        self.exchange = exchange
        self.manager = manager or ScriptedManager()
        self.turns = 0
        self.stopped = False

    def start(self, prompt: str) -> str:
        self._answer_pending()
        return "scripted-manager"

    def deliver(self, node_id: str, message: str) -> None:
        self._answer_pending()

    def stop(self, node_id: str) -> None:
        self.stopped = True

    def _answer_pending(self) -> None:
        for turn_path in sorted(self.exchange.root.glob("turn-*.json")):
            turn = json.loads(turn_path.read_text(encoding="utf-8"))
            reply_path = self.exchange.reply_path(turn["turn"])
            if reply_path.exists():
                continue
            reply_path.write_text(json.dumps(self.manager.answer(turn)), encoding="utf-8")
            self.turns += 1
