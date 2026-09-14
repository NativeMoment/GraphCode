"""ClawArena-Team provider whose every model call is answered by a GraphCode loop."""

from __future__ import annotations

import asyncio
import hashlib
import json
import tempfile
import time
import weakref
from pathlib import Path
from typing import Any

from clawarena_team.provider.base import BaseProvider, ProviderError
from clawarena_team.types import ModelConfig

from .protocol import (
    MANAGER_PROMPT,
    Exchange,
    ReplyError,
    manager_settings,
    parse_reply,
    pointer_message,
    turn_payload,
    unseen_messages,
    workspace_path,
)
from .transport import GraphCodeCLI, Transport, TransportError

_LIVE: "weakref.WeakSet[GraphCodeProvider]" = weakref.WeakSet()


def stop_all() -> None:
    """Stop every loop this process started; the harness has no end-of-scenario hook."""
    for provider in list(_LIVE):
        provider.stop()


class GraphCodeProvider(BaseProvider):
    """``--model`` main entry: ``{"provider": "graphcode", "model_id": "<label>", ...}``.

    Extra keys: ``project`` (graph the loop is created in; defaults to the exchange
    directory), ``exchange_root``, ``backend``, ``graphcode_bin``, ``transport``
    (``cli``, or ``scripted`` for the zero-spend dry run), ``poll_interval_sec``,
    ``turn_timeout_sec``, ``max_reply_retries``.
    """

    name = "graphcode"

    def __init__(self, config: ModelConfig, *, transport: Transport | None = None):
        super().__init__(config)
        extra = config.extra
        root = extra.get("exchange_root")
        base = Path(root) if root else Path(tempfile.mkdtemp(prefix="clawarena-graphcode-"))
        self.exchange = Exchange(base / f"exchange-{int(time.time() * 1000)}")
        self.project = Path(extra.get("project") or self.exchange.root)
        self.poll_interval = float(extra.get("poll_interval_sec", 1.0))
        self.turn_timeout = float(extra.get("turn_timeout_sec", 1800))
        self.max_reply_retries = int(extra.get("max_reply_retries", 1))
        self._transport = transport or self._make_transport(extra)
        self.node_id: str | None = None
        self.turn = 0
        self._seen = 0
        self._tools_digest: str | None = None
        _LIVE.add(self)

    def _make_transport(self, extra: dict[str, Any]) -> Transport:
        kind = extra.get("transport", "cli")
        if kind == "scripted":
            from .stub import ScriptedTransport

            return ScriptedTransport(self.exchange)
        if kind != "cli":
            raise ProviderError(f"unknown graphcode transport {kind!r}")
        return GraphCodeCLI(
            self.project,
            executable=extra.get("graphcode_bin", "graphcode"),
            backend=extra.get("backend"),
        )

    async def chat(
        self,
        *,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None = None,
        **kwargs: Any,
    ) -> dict[str, Any]:
        tools = tools or []
        tool_names = {t["name"] for t in tools}
        new_messages = unseen_messages(messages, self._seen)
        self._seen = len(messages)
        error: str | None = None
        for _ in range(self.max_reply_retries + 1):
            self.turn += 1
            turn = self.turn
            self.exchange.write_turn(
                turn,
                turn_payload(
                    turn=turn,
                    reply_path=self.exchange.reply_path(turn),
                    messages=[] if error else new_messages,
                    tools=self._tools_if_changed(tools),
                    error=error,
                ),
            )
            await asyncio.to_thread(self._wake, turn, messages)
            try:
                reply = await self._await_reply(turn)
                content, calls = parse_reply(reply, tool_names=tool_names, turn=turn)
            except ReplyError as e:
                error = f"reply {turn} rejected: {e}. Answer the same turn again."
                continue
            return self.normalise_response(
                content=content,
                tool_calls=calls,
                extra={"graphcode_node_id": self.node_id, "graphcode_turn": turn},
            )
        raise ProviderError(f"graphcode manager gave no usable reply: {error}")

    def stop(self) -> None:
        if self.node_id is None:
            return
        node_id, self.node_id = self.node_id, None
        try:
            self._transport.stop(node_id)
        except TransportError:
            pass

    def _wake(self, turn: int, messages: list[dict[str, Any]]) -> None:
        try:
            if self.node_id is None:
                self._write_project_settings(workspace_path(messages))
                prompt = f"{MANAGER_PROMPT} {pointer_message(self.exchange, turn)}"
                self.node_id = self._transport.start(prompt)
            else:
                self._transport.deliver(self.node_id, pointer_message(self.exchange, turn))
        except TransportError as e:
            raise ProviderError(str(e)) from e

    def _write_project_settings(self, workspace: str | None) -> None:
        settings = self.project / ".claude" / "settings.json"
        if settings.exists():
            return
        settings.parent.mkdir(parents=True, exist_ok=True)
        settings.write_text(json.dumps(manager_settings(workspace), indent=2), encoding="utf-8")

    async def _await_reply(self, turn: int) -> dict[str, Any]:
        deadline = time.monotonic() + self.turn_timeout
        while True:
            reply = self.exchange.read_reply(turn)
            if reply is not None:
                return reply
            if time.monotonic() >= deadline:
                raise ProviderError(
                    f"graphcode manager wrote no reply to turn {turn} in {self.turn_timeout:.0f}s"
                )
            await asyncio.sleep(self.poll_interval)

    def _tools_if_changed(self, tools: list[dict[str, Any]]) -> list[dict[str, Any]] | None:
        digest = hashlib.sha256(json.dumps(tools, sort_keys=True).encode()).hexdigest()
        if digest == self._tools_digest:
            return None
        self._tools_digest = digest
        return tools
