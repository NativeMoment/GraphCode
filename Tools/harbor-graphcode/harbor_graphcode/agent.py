"""GraphCode as a Harbor installed agent: each task becomes one goal loop.

The loop runs Claude Code under graphcoded inside the task container, so the comparison
with Harbor's plain ``claude-code`` agent isolates what the loop adds. The transcript
Claude Code writes is mirrored into the agent logs, where the inherited ``ClaudeCode``
converter turns it into the ATIF trajectory.
"""

import json
import os
import shlex
from pathlib import Path
from typing import Literal, override

from pydantic import Field

from harbor.agents.installed.base import with_prompt_template
from harbor.agents.installed.claude_code import ClaudeCode, ClaudeCodeOptions
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext
from harbor.models.trial.config import TaskConfig

BUNDLE_DIR_ENV = "GRAPHCODE_LINUX_BUNDLE_DIR"
INSTALL_ROOT = "/opt/graphcode"
# Short on purpose: the daemon's socket lives inside it and sun_path is bounded.
SUPPORT_DIR = "/tmp/gcd"
LOOP_TITLE = "TerminalBenchTask"
ORACLE_CHECK_PATH = "/opt/graphcode-oracle/check.sh"
RESOLVED_STATES = ("succeeded", "failed", "stalled", "stopped")

_ARCH_ALIASES = {
    "x86_64": "x86_64",
    "amd64": "x86_64",
    "aarch64": "aarch64",
    "arm64": "aarch64",
}

# graphcoded launches every session through `/bin/zsh -i -l`, and task images rarely
# ship zsh.
_SYSTEM_PACKAGES_COMMAND = """set -eu
missing=0
for tool in zsh tar ps; do command -v "$tool" >/dev/null 2>&1 || missing=1; done
if [ "$missing" = 1 ]; then
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zsh tar procps ca-certificates >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q zsh tar procps-ng
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q zsh tar procps-ng
  elif command -v apk >/dev/null 2>&1; then
    echo "graphcode: musl images are unsupported (the bundle links glibc)" >&2
    exit 1
  else
    echo "graphcode: no package manager to install zsh with" >&2
    exit 1
  fi
fi
[ -x /bin/zsh ] || ln -sf "$(command -v zsh)" /bin/zsh
"""

# Harbor scores a task by the reward test.sh writes, not by its exit status, so the done
# check reads the reward back and removes it: the verifier must start from a clean slate.
ORACLE_CHECK_SCRIPT = """#!/bin/bash
mkdir -p /logs/verifier
bash /tests/test.sh > /tmp/graphcode-oracle.out 2>&1 || true
reward="$(cat /logs/verifier/reward.txt 2>/dev/null || echo 0)"
rm -f /logs/verifier/reward.txt /logs/verifier/reward.json
tail -n 40 /tmp/graphcode-oracle.out
awk -v r="$reward" 'BEGIN { exit !(r + 0 >= 1) }'
"""


class GraphCodeOptions(ClaudeCodeOptions):
    bundle_dir: str | None = Field(
        default=None,
        description=(
            "Host directory holding graphcode-linux-<arch>.tar.gz "
            f"(falls back to ${BUNDLE_DIR_ENV})."
        ),
    )
    done_check: Literal["agent", "tests"] = Field(
        default="agent",
        description=(
            "agent: no predicate; the loop resolves when the session runs `graphcode "
            "node done` — the same information plain claude-code gets. tests (opt-in): "
            "the loop's predicate is the task's own test.sh, an oracle claude-code does "
            "not get, so it only measures an upper bound."
        ),
    )
    tests_dir: str | None = Field(
        default=None,
        description="Host tests directory; defaults to the trial's task tests/.",
    )
    poll_interval_sec: int = Field(default=10, ge=1)
    budget_tokens: int | None = Field(default=None, ge=1)


def normalize_arch(uname: str) -> str:
    machine = uname.strip().splitlines()[-1].strip() if uname.strip() else ""
    try:
        return _ARCH_ALIASES[machine]
    except KeyError:
        raise ValueError(f"Unsupported container architecture: {machine!r}") from None


def parse_node_id(status_output: str, title: str = LOOP_TITLE) -> str | None:
    """The id of the goal loop titled ``title`` in ``graphcode status`` output."""
    for line in status_output.splitlines():
        fields = line.split()
        if len(fields) >= 4 and fields[2] == "goalBased" and fields[3] == title:
            return fields[0]
    return None


def parse_node_state(status_output: str, node_id: str) -> str | None:
    for line in status_output.splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[0] == node_id:
            return fields[1]
    return None


class GraphCode(ClaudeCode):
    options_model = GraphCodeOptions
    options: GraphCodeOptions

    @staticmethod
    @override
    def name() -> str:
        return "graphcode"

    @override
    def get_version_command(self) -> str | None:
        return None

    def _bundle_dir(self) -> Path:
        configured = self.options.bundle_dir or os.environ.get(BUNDLE_DIR_ENV)
        if not configured:
            raise ValueError(
                f"Set the bundle_dir agent kwarg or ${BUNDLE_DIR_ENV} to the directory "
                "build-linux-bundle.sh wrote"
            )
        return Path(configured).expanduser()

    def bundle_path(self, arch: str) -> Path:
        path = self._bundle_dir() / f"graphcode-linux-{arch}.tar.gz"
        if not path.is_file():
            raise FileNotFoundError(f"No GraphCode Linux bundle at {path}")
        return path

    def resolve_tests_dir(self) -> Path:
        if self.options.tests_dir:
            tests = Path(self.options.tests_dir).expanduser()
        else:
            config_path = self.logs_dir.parent / "config.json"
            if not config_path.is_file():
                raise FileNotFoundError(
                    f"No trial config at {config_path}; pass the tests_dir agent kwarg"
                )
            task = TaskConfig.model_validate(json.loads(config_path.read_text())["task"])
            tests = task.get_local_path() / "tests"
        if not (tests / "test.sh").is_file():
            raise FileNotFoundError(f"No test.sh in {tests}")
        return tests

    @override
    async def install(self, environment: BaseEnvironment) -> None:
        await self.exec_as_root(environment, command=_SYSTEM_PACKAGES_COMMAND)
        await super().install(environment)

        uname = await environment.exec(command="uname -m", user="root")
        bundle = self.bundle_path(normalize_arch(uname.stdout or ""))
        remote_bundle = "/tmp/graphcode-linux.tar.gz"
        await environment.upload_file(bundle, remote_bundle)
        await self.exec_as_root(
            environment,
            command=(
                "set -eu; "
                f"mkdir -p {INSTALL_ROOT} && "
                f"tar -xzf {remote_bundle} -C {INSTALL_ROOT} && "
                f"rm -f {remote_bundle} && "
                f"chmod 755 {INSTALL_ROOT}/bin/* && "
                f"ln -sf {INSTALL_ROOT}/bin/graphcode /usr/local/bin/graphcode && "
                f"ln -sf {INSTALL_ROOT}/bin/graphcoded /usr/local/bin/graphcoded && "
                f"test -x {INSTALL_ROOT}/bin/zmx"
            ),
        )

    def session_env(self) -> dict[str, str]:
        env = self._resolve_auth_env()
        model = self._resolved_model_name()
        if model:
            # graphcode passes `--model haiku|sonnet|opus` by loop tier; pinning every
            # alias keeps the comparison on the one model Harbor was asked for.
            env["ANTHROPIC_MODEL"] = model
            env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = model
            env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = model
            env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = model
            env["CLAUDE_CODE_SUBAGENT_MODEL"] = model
        env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        env["IS_SANDBOX"] = "1"
        env["GRAPHCODE_SUPPORT_DIR"] = SUPPORT_DIR
        return env

    def start_daemon_command(self) -> str:
        settings = json.dumps(
            {
                "defaultBackend": "claudeCode",
                "claudePermissionMode": "bypassPermissions",
            }
        )
        claude_settings = json.dumps({"skipDangerousModePermissionPrompt": True})
        return f"""set -eu
export PATH="$HOME/.local/bin:{INSTALL_ROOT}/bin:$PATH"
mkdir -p "$GRAPHCODE_SUPPORT_DIR/bin" /logs/agent/graphcode "$HOME/.claude"
cp {INSTALL_ROOT}/bin/zmx "$GRAPHCODE_SUPPORT_DIR/bin/zmx"
printf '%s\\n' {shlex.quote(settings)} > "$GRAPHCODE_SUPPORT_DIR/settings.json"
printf 'export PATH="$HOME/.local/bin:{INSTALL_ROOT}/bin:$PATH"\\n' >> "$HOME/.zshenv"
[ -f "$HOME/.claude/settings.json" ] || printf '%s\\n' {shlex.quote(claude_settings)} > "$HOME/.claude/settings.json"
if [ ! -f "$HOME/.claude.json" ]; then
  key_tail="$(printf '%s' "${{ANTHROPIC_API_KEY:-}}" | tail -c 20)"
  printf '{{"hasCompletedOnboarding":true,"bypassPermissionsModeAccepted":true,"customApiKeyResponses":{{"approved":["%s"],"rejected":[]}}}}\\n' "$key_tail" > "$HOME/.claude.json"
fi
setsid nohup graphcoded > /logs/agent/graphcode/graphcoded.log 2>&1 < /dev/null &
for _ in $(seq 1 60); do
  [ -S "$GRAPHCODE_SUPPORT_DIR/graphcoded.sock" ] && exit 0
  sleep 0.5
done
echo "graphcode: graphcoded never listened" >&2
cat /logs/agent/graphcode/graphcoded.log >&2
exit 1
"""

    def create_and_wait_command(self, predicate: str | None) -> str:
        create = [
            "graphcode",
            "node",
            "create",
            '"$project"',
            "--title",
            LOOP_TITLE,
            "--type",
            "goal",
            "--backend",
            "claudeCode",
            "--goal",
            '"$GRAPHCODE_TB_GOAL"',
        ]
        if predicate:
            create += ["--predicate", shlex.quote(predicate)]
        if self.options.budget_tokens:
            create += ["--budget", str(self.options.budget_tokens)]
        resolved = "|".join(RESOLVED_STATES)
        return f"""set -u
export PATH="$HOME/.local/bin:{INSTALL_ROOT}/bin:$PATH"
project="$(pwd)"
logs=/logs/agent/graphcode
mirror() {{
  if [ -d "$HOME/.claude/projects" ]; then
    mkdir -p /logs/agent/sessions/projects
    cp -R "$HOME/.claude/projects/." /logs/agent/sessions/projects/ 2>/dev/null || true
  fi
  graphcode status "$project" > "$logs/status.txt" 2>&1 || true
  [ -d "$GRAPHCODE_SUPPORT_DIR/memory" ] && cp -R "$GRAPHCODE_SUPPORT_DIR/memory" "$logs/" 2>/dev/null || true
}}
{" ".join(create)} > "$logs/create.txt" 2>&1 || {{ cat "$logs/create.txt" >&2; exit 1; }}
node="$(awk '$3 == "goalBased" && $4 == "{LOOP_TITLE}" {{ print $1; exit }}' "$logs/create.txt")"
[ -n "$node" ] || {{ echo "graphcode: no loop id in create output" >&2; cat "$logs/create.txt" >&2; exit 1; }}
echo "$node" > "$logs/node-id.txt"
exited=0
while :; do
  sleep {self.options.poll_interval_sec}
  mirror
  line="$(awk -v id="$node" '$1 == id' "$logs/status.txt")"
  state="$(printf '%s\\n' "$line" | awk '{{ print $2 }}')"
  case "$state" in {resolved}) break ;; esac
  # A session that exited without resolving the loop would otherwise hold the trial
  # until Harbor's timeout.
  case "$line" in *"session exited"*) exited=$((exited + 1)) ;; *) exited=0 ;; esac
  [ "$exited" -ge 6 ] && break
done
echo "$state" > "$logs/final-state.txt"
mirror
"""

    @override
    @with_prompt_template
    async def run(
        self, instruction: str, environment: BaseEnvironment, context: AgentContext
    ) -> None:
        predicate = None
        if self.options.done_check == "tests":
            await environment.upload_dir(self.resolve_tests_dir(), "/tests")
            await self.exec_as_root(
                environment, command=f"mkdir -p {Path(ORACLE_CHECK_PATH).parent}"
            )
            await self._upload_config_text(
                environment,
                content=ORACLE_CHECK_SCRIPT,
                remote_path=ORACLE_CHECK_PATH,
                filename="check.sh",
            )
            predicate = f"bash {ORACLE_CHECK_PATH}"

        env = self.session_env()
        await self.exec_as_agent(
            environment, command=self.start_daemon_command(), env=env
        )
        await self.exec_as_agent(
            environment,
            command=self.create_and_wait_command(predicate),
            env={**env, "GRAPHCODE_TB_GOAL": instruction},
        )
