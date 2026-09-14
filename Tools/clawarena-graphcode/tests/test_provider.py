import json
from pathlib import Path

import pytest

from clawarena_team.provider.base import ProviderError
from clawarena_team.types import ModelConfig

from clawarena_graphcode.provider import GraphCodeProvider, stop_all
from clawarena_graphcode.protocol import MANAGER_PROMPT
from clawarena_graphcode.stub import ScriptedTransport

TOOLS = [
    {"name": "Read", "description": "", "parameters": {"type": "object"}},
    {"name": "CreateSubagent", "description": "", "parameters": {"type": "object"}},
]
ENV = (
    "<system-reminder>\nEnvironment\n  cwd: /runs/s/work\n"
    "  delegable_paths (you CANNOT touch these yourself):\n    - /runs/s/work/code\n"
    "  modalities_natively_supported: text\n</system-reminder>"
)


class QueueTransport:
    """Writes queued replies to whichever turn was just delivered."""

    def __init__(self, replies):
        self.replies = list(replies)
        self.provider: GraphCodeProvider | None = None
        self.started: list[str] = []
        self.delivered: list[str] = []
        self.stopped: list[str] = []

    def start(self, prompt):
        self.started.append(prompt)
        self._reply()
        return "NODE-1"

    def deliver(self, node_id, message):
        assert node_id == "NODE-1"
        self.delivered.append(message)
        self._reply()

    def stop(self, node_id):
        self.stopped.append(node_id)

    def _reply(self):
        if not self.replies:
            return
        reply = self.replies.pop(0)
        text = reply if isinstance(reply, str) else json.dumps(reply)
        self.provider.exchange.reply_path(self.provider.turn).write_text(text)


def make(tmp_path: Path, replies, **extra):
    config = ModelConfig(
        provider="graphcode",
        model_id="graphcode-opus",
        extra={"exchange_root": str(tmp_path), "poll_interval_sec": 0.01, **extra},
    )
    transport = QueueTransport(replies)
    provider = GraphCodeProvider(config, transport=transport)
    transport.provider = provider
    return provider, transport


def turn_file(provider: GraphCodeProvider, turn: int) -> dict:
    return json.loads(provider.exchange.turn_path(turn).read_text())


async def test_first_call_starts_the_loop_then_later_calls_deliver(tmp_path):
    provider, transport = make(
        tmp_path,
        [
            {"content": "", "tool_calls": [{"name": "Read", "arguments": {"file_path": "/a"}}]},
            {"content": "final"},
        ],
    )
    first = [{"role": "system", "content": "sys"}, {"role": "user", "content": "q " + ENV}]
    resp = await provider.chat(messages=first, tools=TOOLS)
    assert resp["tool_calls"] == [{"id": "gc-1-0", "name": "Read", "arguments": {"file_path": "/a"}}]
    assert resp["model_id"] == "graphcode-opus"
    assert resp["extra"] == {"graphcode_node_id": "NODE-1", "graphcode_turn": 1}
    assert transport.started[0].startswith(MANAGER_PROMPT)
    assert str(provider.exchange.turn_path(1)) in transport.started[0]
    assert turn_file(provider, 1)["tools"] == TOOLS

    second = first + [
        {"role": "assistant", "content": "", "tool_calls": resp["tool_calls"]},
        {"role": "tool", "tool_call_id": "gc-1-0", "content": "file body"},
    ]
    resp = await provider.chat(messages=second, tools=TOOLS)
    assert resp["content"] == "final" and resp["tool_calls"] == []
    payload = turn_file(provider, 2)
    assert payload["messages"] == [{"role": "tool", "tool_call_id": "gc-1-0", "content": "file body"}]
    assert "tools" not in payload
    assert len(transport.delivered) == 1 and "\n" not in transport.delivered[0]


async def test_loop_project_denies_direct_workspace_access(tmp_path):
    provider, _ = make(tmp_path, [{"content": "ok"}])
    await provider.chat(messages=[{"role": "user", "content": "q " + ENV}], tools=TOOLS)
    settings = json.loads((provider.project / ".claude" / "settings.json").read_text())
    assert "Read(//runs/s/work/**)" in settings["permissions"]["deny"]
    assert "Agent" in settings["permissions"]["deny"]


async def test_changed_tools_are_resent(tmp_path):
    provider, _ = make(tmp_path, [{"content": "a"}, {"content": "b"}])
    await provider.chat(messages=[{"role": "user", "content": "q"}], tools=TOOLS)
    more = TOOLS + [{"name": "StructuredOutput", "description": "", "parameters": {}}]
    await provider.chat(messages=[{"role": "user", "content": "q"}], tools=more)
    assert turn_file(provider, 2)["tools"] == more


async def test_rejected_reply_is_retried_as_a_new_turn(tmp_path):
    provider, transport = make(
        tmp_path,
        [{"tool_calls": [{"name": "Bash", "arguments": {}}]}, {"content": "fixed"}],
    )
    resp = await provider.chat(messages=[{"role": "user", "content": "q"}], tools=TOOLS)
    assert resp["content"] == "fixed"
    retry = turn_file(provider, 2)
    assert "unknown tool 'Bash'" in retry["error"] and retry["messages"] == []
    assert len(transport.delivered) == 1


async def test_gives_up_after_retries(tmp_path):
    bad = {"tool_calls": [{"name": "Bash"}]}
    provider, _ = make(tmp_path, [bad, bad, bad], max_reply_retries=1)
    with pytest.raises(ProviderError, match="no usable reply"):
        await provider.chat(messages=[{"role": "user", "content": "q"}], tools=TOOLS)


async def test_silent_loop_times_out(tmp_path):
    provider, _ = make(tmp_path, [], turn_timeout_sec=0.05)
    with pytest.raises(ProviderError, match="wrote no reply to turn 1"):
        await provider.chat(messages=[{"role": "user", "content": "q"}], tools=TOOLS)


async def test_stop_all_stops_started_loops_once(tmp_path):
    provider, transport = make(tmp_path, [{"content": "ok"}])
    await provider.chat(messages=[{"role": "user", "content": "q"}], tools=TOOLS)
    stop_all()
    stop_all()
    assert transport.stopped == ["NODE-1"]


async def test_scripted_manager_delegates_through_the_exchange(tmp_path):
    config = ModelConfig(
        provider="graphcode",
        model_id="dry",
        extra={"exchange_root": str(tmp_path), "transport": "scripted", "poll_interval_sec": 0.01},
    )
    provider = GraphCodeProvider(config)
    assert isinstance(provider._transport, ScriptedTransport)
    tools = TOOLS + [{"name": "RunSubagent", "description": "", "parameters": {}}]
    history = [{"role": "user", "content": "find the root cause " + ENV}]

    resp = await provider.chat(messages=history, tools=tools)
    (create,) = resp["tool_calls"]
    assert create["name"] == "CreateSubagent"
    assert create["arguments"]["accessible_paths"] == ["/runs/s/work/code"]
    assert create["arguments"]["model_key"] == "llm"

    history += [
        {"role": "assistant", "content": "", "tool_calls": resp["tool_calls"]},
        {"role": "tool", "tool_call_id": create["id"], "content": "subagent_id=sub_42"},
    ]
    resp = await provider.chat(messages=history, tools=tools)
    (run,) = resp["tool_calls"]
    assert run["name"] == "RunSubagent" and run["arguments"]["subagent_id"] == "sub_42"
    assert run["arguments"]["prompt"] == "find the root cause"

    history += [
        {"role": "assistant", "content": "", "tool_calls": resp["tool_calls"]},
        {"role": "tool", "tool_call_id": run["id"], "content": "[stub stub-llm] no model"},
    ]
    resp = await provider.chat(messages=history, tools=tools)
    assert resp["tool_calls"] == [] and "sub_42" in resp["content"]
