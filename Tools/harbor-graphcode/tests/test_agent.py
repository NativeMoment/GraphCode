import json
import os
import subprocess
from pathlib import Path
from unittest.mock import AsyncMock, patch

import pytest

from harbor.agents.installed.claude_code import ClaudeCode
from harbor_graphcode.agent import (
    BUNDLE_DIR_ENV,
    GraphCode,
    ORACLE_CHECK_PATH,
    ORACLE_CHECK_SCRIPT,
    normalize_arch,
    parse_node_id,
    parse_node_state,
)

STATUS = """app  (running)
  8209FF6E-3116-42E6-9A5F-46386D43CE57  running  goalBased  TerminalBenchTask
  11111111-2222-3333-4444-555555555555  idle  timeBased  Watcher
"""


def make_agent(tmp_path: Path, **kwargs) -> GraphCode:
    logs = tmp_path / "trial" / "agent"
    logs.mkdir(parents=True)
    return GraphCode(logs_dir=logs, model_name="anthropic/claude-opus-5", **kwargs)


def ok_env(stdout: str = "") -> AsyncMock:
    environment = AsyncMock()
    environment.default_user = None
    environment.exec.return_value = AsyncMock(return_code=0, stdout=stdout, stderr="")
    return environment


def commands(environment: AsyncMock) -> list[str]:
    return [call.kwargs["command"] for call in environment.exec.call_args_list]


class TestParsing:
    def test_node_id_is_the_goal_loop_with_the_task_title(self):
        assert parse_node_id(STATUS) == "8209FF6E-3116-42E6-9A5F-46386D43CE57"

    def test_node_id_absent_when_no_goal_loop(self):
        assert parse_node_id("app  (idle)\n  no loops yet") is None

    def test_state_reads_display_state_column(self):
        assert parse_node_state(STATUS, "11111111-2222-3333-4444-555555555555") == "idle"
        assert parse_node_state(STATUS, "missing") is None

    @pytest.mark.parametrize(
        ("uname", "arch"),
        [("x86_64\n", "x86_64"), ("amd64", "x86_64"), ("aarch64", "aarch64"), ("arm64\n", "aarch64")],
    )
    def test_arch_aliases(self, uname, arch):
        assert normalize_arch(uname) == arch

    def test_unknown_arch_is_refused(self):
        with pytest.raises(ValueError):
            normalize_arch("riscv64")


class TestShellScripts:
    """The container scripts run under bash; the awk the adapter relies on must agree
    with the Python parsers on real status output."""

    def test_generated_scripts_parse(self, tmp_path):
        agent = make_agent(tmp_path)
        for script in (
            agent.start_daemon_command(),
            agent.create_and_wait_command("bash /opt/graphcode-oracle/check.sh"),
            ORACLE_CHECK_SCRIPT,
        ):
            subprocess.run(["bash", "-n"], input=script, text=True, check=True)

    def test_awk_node_id_matches_python(self, tmp_path):
        agent = make_agent(tmp_path)
        script = agent.create_and_wait_command(None)
        awk_line = next(line for line in script.splitlines() if line.startswith("node="))
        program = awk_line.split("awk '", 1)[1].split("'", 1)[0]
        status = tmp_path / "create.txt"
        status.write_text(STATUS)
        out = subprocess.run(
            ["awk", program, str(status)], capture_output=True, text=True, check=True
        ).stdout.strip()
        assert out == parse_node_id(STATUS)

    @pytest.mark.parametrize(("reward", "passes"), [("1", True), ("1.0", True), ("0", False), ("0.5", False)])
    def test_oracle_check_reads_reward_and_clears_it(self, tmp_path, reward, passes):
        verifier = tmp_path / "verifier"
        tests = tmp_path / "tests"
        tests.mkdir()
        (tests / "test.sh").write_text(f"echo {reward} > {verifier}/reward.txt\n")
        script = (
            ORACLE_CHECK_SCRIPT.replace("/logs/verifier", str(verifier))
            .replace("/tests/test.sh", str(tests / "test.sh"))
            .replace("/tmp/graphcode-oracle.out", str(tmp_path / "out"))
        )
        result = subprocess.run(["bash", "-c", script])
        assert (result.returncode == 0) is passes
        assert not (verifier / "reward.txt").exists()


class TestCreateCommand:
    def test_tests_mode_uses_the_oracle_predicate(self, tmp_path):
        agent = make_agent(tmp_path)
        script = agent.create_and_wait_command(f"bash {ORACLE_CHECK_PATH}")
        assert f"--predicate 'bash {ORACLE_CHECK_PATH}'" in script
        assert '--goal "$GRAPHCODE_TB_GOAL"' in script
        assert "--backend claudeCode" in script

    def test_agent_mode_has_no_predicate(self, tmp_path):
        agent = make_agent(tmp_path, done_check="agent")
        assert "--predicate" not in agent.create_and_wait_command(None)

    def test_budget_is_passed_through(self, tmp_path):
        agent = make_agent(tmp_path, budget_tokens=2_000_000)
        assert "--budget 2000000" in agent.create_and_wait_command(None)

    def test_transcripts_are_mirrored_where_claude_code_looks(self, tmp_path):
        script = make_agent(tmp_path).create_and_wait_command(None)
        assert "/logs/agent/sessions/projects" in script


class TestSessionEnv:
    def test_every_tier_alias_is_pinned_to_the_harbor_model(self, tmp_path):
        agent = make_agent(tmp_path)
        with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "sk-test"}, clear=False):
            env = agent.session_env()
        for key in (
            "ANTHROPIC_MODEL",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL",
            "ANTHROPIC_DEFAULT_SONNET_MODEL",
            "ANTHROPIC_DEFAULT_OPUS_MODEL",
        ):
            assert env[key] == "claude-opus-5"
        assert env["IS_SANDBOX"] == "1"
        assert env["GRAPHCODE_SUPPORT_DIR"] == "/tmp/gcd"

    def test_daemon_script_never_prints_the_key(self, tmp_path):
        with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "sk-secret-value"}, clear=False):
            script = make_agent(tmp_path).start_daemon_command()
        assert "sk-secret-value" not in script
        assert '"claudePermissionMode": "bypassPermissions"' in script


class TestInstall:
    async def test_uploads_the_bundle_for_the_container_arch(self, tmp_path):
        bundles = tmp_path / "dist"
        bundles.mkdir()
        (bundles / "graphcode-linux-x86_64.tar.gz").write_bytes(b"bundle")
        agent = make_agent(tmp_path, bundle_dir=str(bundles))
        environment = ok_env(stdout="x86_64\n")
        with patch.object(ClaudeCode, "install", AsyncMock()) as claude_install:
            await agent.install(environment)

        claude_install.assert_awaited_once()
        environment.upload_file.assert_awaited_once_with(
            bundles / "graphcode-linux-x86_64.tar.gz", "/tmp/graphcode-linux.tar.gz"
        )
        issued = commands(environment)
        assert any("apt-get install" in c and "zsh" in c for c in issued)
        assert any("ln -sf /opt/graphcode/bin/graphcode /usr/local/bin/graphcode" in c for c in issued)

    async def test_missing_bundle_fails_before_upload(self, tmp_path):
        agent = make_agent(tmp_path, bundle_dir=str(tmp_path))
        environment = ok_env(stdout="aarch64")
        with patch.object(ClaudeCode, "install", AsyncMock()):
            with pytest.raises(FileNotFoundError):
                await agent.install(environment)
        environment.upload_file.assert_not_awaited()

    async def test_bundle_dir_falls_back_to_the_environment(self, tmp_path):
        (tmp_path / "graphcode-linux-aarch64.tar.gz").write_bytes(b"bundle")
        agent = make_agent(tmp_path)
        with patch.dict(os.environ, {BUNDLE_DIR_ENV: str(tmp_path)}):
            assert agent.bundle_path("aarch64").is_file()


class TestRun:
    def write_task(self, tmp_path: Path) -> Path:
        task = tmp_path / "task"
        (task / "tests").mkdir(parents=True)
        (task / "tests" / "test.sh").write_text("#!/bin/bash\n")
        return task

    def test_tests_dir_comes_from_the_trial_config(self, tmp_path):
        task = self.write_task(tmp_path)
        agent = make_agent(tmp_path)
        (tmp_path / "trial" / "config.json").write_text(
            json.dumps({"task": {"path": str(task)}, "trial_name": "t"})
        )
        assert agent.resolve_tests_dir() == task / "tests"

    async def test_tests_mode_uploads_tests_then_creates_a_predicated_loop(self, tmp_path):
        task = self.write_task(tmp_path)
        agent = make_agent(tmp_path, tests_dir=str(task / "tests"))
        environment = ok_env()
        with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "sk-test"}, clear=False):
            await agent.run("Make the tests pass", environment, AsyncMock())

        environment.upload_dir.assert_awaited_once_with(task / "tests", "/tests")
        last = environment.exec.call_args_list[-1].kwargs
        assert "--predicate" in last["command"]
        assert last["env"]["GRAPHCODE_TB_GOAL"] == "Make the tests pass"
        assert "Make the tests pass" not in last["command"]

    async def test_agent_mode_uploads_nothing(self, tmp_path):
        agent = make_agent(tmp_path, done_check="agent")
        environment = ok_env()
        with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "sk-test"}, clear=False):
            await agent.run("Do the task", environment, AsyncMock())
        environment.upload_dir.assert_not_awaited()
        assert "--predicate" not in environment.exec.call_args_list[-1].kwargs["command"]
