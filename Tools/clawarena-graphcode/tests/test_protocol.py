import json

import pytest

from clawarena_graphcode.protocol import (
    Exchange,
    ReplyError,
    delegable_paths,
    manager_settings,
    parse_reply,
    pointer_message,
    unseen_messages,
    workspace_path,
)

ENV = (
    "Environment\n"
    "  scenario_id: s_demo\n"
    "  cwd: /runs/s_demo/work\n"
    "  accessible_paths (you can Read here directly):\n"
    "    - /runs/s_demo/work/briefs\n"
    "  delegable_paths (you CANNOT touch these yourself — delegate):\n"
    "    - /runs/s_demo/work/code\n"
    "    - /runs/s_demo/work/traces\n"
    "  modalities_natively_supported: text\n"
)


def test_unseen_messages_skip_seen_and_assistant_echoes():
    messages = [
        {"role": "system", "content": "sys"},
        {"role": "user", "content": "q1"},
        {"role": "assistant", "content": "", "tool_calls": [{"id": "1"}]},
        {"role": "tool", "tool_call_id": "1", "content": "result"},
    ]
    assert unseen_messages(messages, 2) == [{"role": "tool", "tool_call_id": "1", "content": "result"}]
    assert [m["role"] for m in unseen_messages(messages, 0)] == ["system", "user", "tool"]


def test_unseen_messages_flatten_multimodal_parts():
    message = {"role": "user", "content": [{"type": "image_url"}, {"type": "text", "text": "look"}]}
    (flat,) = unseen_messages([message], 0)
    assert flat["content"] == "[image_url omitted: the manager is text-only]\nlook"


def test_parse_reply_normalises_calls():
    content, calls = parse_reply(
        {
            "content": "delegating",
            "tool_calls": [
                {"name": "CreateSubagent", "arguments": {"name": "a"}},
                {"name": "Read", "arguments": '{"file_path": "/x"}', "id": "mine"},
            ],
        },
        tool_names={"CreateSubagent", "Read"},
        turn=3,
    )
    assert content == "delegating"
    assert calls == [
        {"id": "gc-3-0", "name": "CreateSubagent", "arguments": {"name": "a"}},
        {"id": "mine", "name": "Read", "arguments": {"file_path": "/x"}},
    ]


def test_parse_reply_without_calls_is_a_final_answer():
    assert parse_reply({"content": "done"}, tool_names=set(), turn=1) == ("done", [])


@pytest.mark.parametrize(
    "reply, message",
    [
        ({"tool_calls": [{"name": "Bash", "arguments": {}}]}, "unknown tool 'Bash'"),
        ({"tool_calls": {"name": "Read"}}, "must be a list"),
        ({"tool_calls": [{"name": "Read", "arguments": "{nope"}]}, "not JSON"),
        ({"tool_calls": [{"name": "Read", "arguments": [1]}]}, "must be an object"),
        ({"content": 7}, "content must be a string"),
    ],
)
def test_parse_reply_rejects_malformed(reply, message):
    with pytest.raises(ReplyError, match=message):
        parse_reply(reply, tool_names={"Read"}, turn=1)


def test_exchange_round_trip_and_partial_reply(tmp_path):
    exchange = Exchange(tmp_path / "ex")
    path = exchange.write_turn(1, {"turn": 1})
    assert json.loads(path.read_text()) == {"turn": 1}
    assert not list(exchange.root.glob("*.tmp"))
    assert exchange.read_reply(1) is None
    exchange.reply_path(1).write_text('{"content": "hal')
    assert exchange.read_reply(1) is None
    exchange.reply_path(1).write_text('```json\n{"content": "ok"}\n```')
    assert exchange.read_reply(1) == {"content": "ok"}
    exchange.reply_path(1).write_text("[1, 2]")
    with pytest.raises(ReplyError):
        exchange.read_reply(1)


def test_pointer_message_is_one_line(tmp_path):
    message = pointer_message(Exchange(tmp_path), 12)
    assert "\n" not in message
    assert "turn-0012.json" in message and "reply-0012.json" in message


def test_environment_parsing():
    messages = [{"role": "user", "content": "question\n\n<system-reminder>\n" + ENV + "</system-reminder>"}]
    assert delegable_paths(messages) == ["/runs/s_demo/work/code", "/runs/s_demo/work/traces"]
    assert workspace_path(messages) == "/runs/s_demo/work"
    assert delegable_paths([{"role": "user", "content": "none"}]) == []


def test_manager_settings_deny_direct_work():
    deny = manager_settings("/runs/s_demo/work")["permissions"]["deny"]
    for tool in ("Bash", "Agent", "Task", "WebFetch", "WebSearch"):
        assert tool in deny
    assert "Read(//runs/s_demo/work/**)" in deny
    assert "Edit(//runs/s_demo/work/**)" in deny
    assert not any("(" in rule for rule in manager_settings(None)["permissions"]["deny"])
