"""The file exchange between the ClawArena harness and the manager loop.

The harness owns the tools: every Read, CreateSubagent or Workflow the manager asks for is
executed, sandboxed and scored by ClawArena. The loop only decides. Each model call the
harness makes becomes one turn file holding the messages the loop has not seen yet; the
loop answers with one reply file naming the tool calls it wants, or a final answer.

Files carry the content because `graphcode node send` flattens newlines and clips long
messages; the message that wakes the loop is only a pointer.
"""

from __future__ import annotations

import json
import os
import re
from pathlib import Path
from typing import Any

MANAGER_PROMPT = (
    "You are the main agent (manager) in a ClawArena-Team benchmark scenario. The benchmark "
    "harness owns every tool; you only decide. Turns arrive as JSON files: read the turn file "
    "named in each message. It holds the new conversation messages since your last reply "
    "(system, user and tool results, with <system-reminder> and <task-notification> blocks) "
    "and, when they change, the tool schemas you may call. Answer each turn by writing exactly "
    "one JSON object to the reply path the message names: "
    '{"content": "<text>", "tool_calls": [{"name": "<tool>", "arguments": {...}}]}. '
    "Request tools only through tool_calls; several calls in one reply run in parallel. A "
    "reply with no tool_calls is your final answer to the current user question. Never read, "
    "search or edit the scenario workspace yourself, never run shell commands and never start "
    "your own subagents: the harness scores only what goes through tool_calls, and doing any "
    "of it directly invalidates the run. After writing the reply, end your turn and wait for "
    "the next message."
)

_ASSISTANT = "assistant"
_DELEGABLE_RE = re.compile(r"delegable_paths[^\n]*\n((?:[ \t]+- [^\n]+\n?)+)")
_CWD_RE = re.compile(r"^\s*cwd: (.+)$", re.MULTILINE)


class ReplyError(ValueError):
    """The loop's reply cannot be turned into a model response."""


class Exchange:
    def __init__(self, root: Path):
        self.root = root

    def turn_path(self, turn: int) -> Path:
        return self.root / f"turn-{turn:04d}.json"

    def reply_path(self, turn: int) -> Path:
        return self.root / f"reply-{turn:04d}.json"

    def write_turn(self, turn: int, payload: dict[str, Any]) -> Path:
        self.root.mkdir(parents=True, exist_ok=True)
        path = self.turn_path(turn)
        tmp = path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(tmp, path)
        return path

    def read_reply(self, turn: int) -> dict[str, Any] | None:
        """The reply once it parses; a half-written file reads as not there yet."""
        path = self.reply_path(turn)
        try:
            text = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            return None
        try:
            value = json.loads(_strip_fence(text))
        except json.JSONDecodeError:
            return None
        if not isinstance(value, dict):
            raise ReplyError(f"{path.name} must hold a JSON object, got {type(value).__name__}")
        return value


def pointer_message(exchange: Exchange, turn: int) -> str:
    return (
        f"ClawArena turn {turn}: read {exchange.turn_path(turn)} and write your reply JSON "
        f"to {exchange.reply_path(turn)}."
    )


def unseen_messages(messages: list[dict[str, Any]], seen: int) -> list[dict[str, Any]]:
    """Messages past ``seen``, minus the loop's own replies echoed back by the harness."""
    return [_flatten(m) for m in messages[seen:] if m.get("role") != _ASSISTANT]


def turn_payload(
    *,
    turn: int,
    reply_path: Path,
    messages: list[dict[str, Any]],
    tools: list[dict[str, Any]] | None,
    error: str | None = None,
) -> dict[str, Any]:
    payload: dict[str, Any] = {"turn": turn, "reply_path": str(reply_path), "messages": messages}
    if tools is not None:
        payload["tools"] = tools
    if error:
        payload["error"] = error
    return payload


def parse_reply(
    reply: dict[str, Any], *, tool_names: set[str], turn: int
) -> tuple[str, list[dict[str, Any]]]:
    content = reply.get("content") or ""
    if not isinstance(content, str):
        raise ReplyError("content must be a string")
    raw_calls = reply.get("tool_calls") or []
    if not isinstance(raw_calls, list):
        raise ReplyError("tool_calls must be a list")
    calls: list[dict[str, Any]] = []
    for index, raw in enumerate(raw_calls):
        if not isinstance(raw, dict):
            raise ReplyError(f"tool_calls[{index}] must be an object")
        name = raw.get("name")
        if name not in tool_names:
            raise ReplyError(f"tool_calls[{index}] names unknown tool {name!r}")
        arguments = raw.get("arguments") or {}
        if isinstance(arguments, str):
            try:
                arguments = json.loads(arguments)
            except json.JSONDecodeError as e:
                raise ReplyError(f"tool_calls[{index}].arguments is not JSON: {e}") from None
        if not isinstance(arguments, dict):
            raise ReplyError(f"tool_calls[{index}].arguments must be an object")
        call_id = raw.get("id") or f"gc-{turn}-{index}"
        calls.append({"id": str(call_id), "name": name, "arguments": arguments})
    return content, calls


def delegable_paths(messages: list[dict[str, Any]]) -> list[str]:
    for message in messages:
        match = _DELEGABLE_RE.search(_text(message))
        if match:
            return [line.strip()[2:].strip() for line in match.group(1).splitlines() if line.strip()]
    return []


def workspace_path(messages: list[dict[str, Any]]) -> str | None:
    for message in messages:
        match = _CWD_RE.search(_text(message))
        if match:
            return match.group(1).strip()
    return None


def manager_settings(workspace: str | None) -> dict[str, Any]:
    """Claude Code permissions for the loop's project: it may read turns and write replies,
    and nothing that would do the harness's work outside the harness."""
    deny = ["Bash", "Agent", "Task", "WebFetch", "WebSearch", "NotebookEdit"]
    if workspace:
        root = "/" + workspace.lstrip("/")
        deny += [f"Read(/{root}/**)", f"Edit(/{root}/**)", f"Glob(/{root}/**)", f"Grep(/{root}/**)"]
    return {"permissions": {"deny": deny}}


def _flatten(message: dict[str, Any]) -> dict[str, Any]:
    out = {k: v for k, v in message.items() if k != "content"}
    out["content"] = _text(message)
    return out


def _text(message: dict[str, Any]) -> str:
    content = message.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for part in content:
            if isinstance(part, dict) and part.get("type") == "text":
                parts.append(part.get("text", ""))
            elif isinstance(part, dict):
                parts.append(f"[{part.get('type', 'part')} omitted: the manager is text-only]")
        return "\n".join(parts)
    return ""


def _strip_fence(text: str) -> str:
    stripped = text.strip()
    if stripped.startswith("```"):
        stripped = stripped.split("\n", 1)[1] if "\n" in stripped else ""
        if stripped.rstrip().endswith("```"):
            stripped = stripped.rstrip()[:-3]
    return stripped
