#!/usr/bin/env python3
"""Round-trip Unicode on macOS through an isolated CLI, daemon, zmx, and recorder.

Usage: python3 scripts/unicode-launch-probe.py GRAPHCODE GRAPHCODED ZMX
The recorder replaces Claude; no model request or installed daemon is involved.
"""
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time


PAYLOAD = "[range M2.1–M2.5 and A1–B2 — done → 😀 cafe\u0301 日本語]"


def wait_for(path, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            return
        time.sleep(0.1)
    raise AssertionError(f"Timed out waiting for {path}")


def probe(cli, daemon_binary, zmx, locale):
    root = Path(tempfile.mkdtemp(prefix="g344-", dir="/tmp"))
    support = root / "s"
    home = root / "home"
    project = root / "project"
    for directory in (support / "bin", home, project):
        directory.mkdir(parents=True)
    shutil.copy2(zmx, support / "bin/zmx")
    (support / "settings.json").write_text(json.dumps({
        "briefsSessionsAboutTheGraph": False, "autoSelectsModel": False,
    }))
    recorder = home / "claude"
    recorder.write_text(
        f"#!{sys.executable}\n"
        "import json, os, pathlib, sys, tty\n"
        "root = pathlib.Path(os.environ['PROBE_ROOT'])\n"
        "tty.setraw(0)\n"
        "(root / 'argv.json').write_text(json.dumps(sys.argv[1:]))\n"
        "(root / 'locale.json').write_text(json.dumps({k: os.environ.get(k) "
        "for k in ('LANG', 'LC_CTYPE', 'LC_ALL')}))\n"
        "(root / 'ready').touch()\n"
        "data = b''\n"
        "while True:\n"
        "    part = os.read(0, 4096)\n"
        "    if not part: break\n"
        "    data += part\n"
        "    if b'\\r' in data:\n"
        "        (root / 'message.tmp').write_bytes(data)\n"
        "        (root / 'message.tmp').replace(root / 'message.bin')\n"
        "        data = b''\n"
    )
    recorder.chmod(0o755)
    (home / ".zshrc").write_text(f'export PATH="{home}:$PATH"\n')
    env = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(home),
        "ZDOTDIR": str(home), "SHELL": "/bin/zsh", "TERM": "xterm-256color",
        "GRAPHCODE_SUPPORT_DIR": str(support), "ZMX_DIR": str(root / "zmx"),
        "PROBE_ROOT": str(root), **locale,
    }
    node_id = None
    with (root / "daemon.log").open("w") as log:
        daemon = subprocess.Popen([daemon_binary], env=env, stdout=log, stderr=log)
        try:
            wait_for(support / "graphcoded.sock")
            result = subprocess.run([
                cli, "node", "create", str(project), "--title", "UnicodeProbe",
                "--type", "goal", "--backend", "claudeCode", "--goal", PAYLOAD,
            ], env=env, capture_output=True, text=True, check=True, timeout=20)
            node_id = re.search(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}",
                                result.stdout).group()
            wait_for(root / "ready")
            argv = json.loads((root / "argv.json").read_text())
            assert any(PAYLOAD in arg for arg in argv), argv
            subprocess.run([cli, "node", "send", str(project), node_id, PAYLOAD],
                           env=env, capture_output=True, check=True, timeout=20)
            wait_for(root / "message.bin")
            message = (root / "message.bin").read_bytes()
            assert PAYLOAD.encode() in message, message
            received = json.loads((root / "locale.json").read_text())
            assert received["LANG"] == (locale.get("LANG") or "en_US.UTF-8"), received
            for key in ("LC_ALL", "LC_CTYPE"):
                assert received[key] == locale.get(key), received
            print(f"PASS locale={locale!r}: launch argv and node send intact; {root}")
        finally:
            daemon.terminate()
            try:
                daemon.wait(timeout=5)
            except subprocess.TimeoutExpired:
                daemon.kill()
                daemon.wait()
            if node_id:
                history = subprocess.run(
                    [str(support / "bin/zmx"), "history", f"graphcode-{node_id}"],
                    env=env, capture_output=True, timeout=10)
                (root / "history.txt").write_bytes(history.stdout + history.stderr)
                subprocess.run([str(support / "bin/zmx"), "kill", f"graphcode-{node_id}"],
                               env=env, capture_output=True, timeout=10)
            print(f"Evidence: {root}")


def main():
    cli, daemon_binary, zmx = (str(Path(arg).resolve()) for arg in sys.argv[1:])
    for locale in ({}, {"LANG": ""}, {"LANG": "fr_FR.UTF-8"},
                   {"LANG": "en_US.UTF-8", "LC_CTYPE": "UTF-8"},
                   {"LC_ALL": "en_US.UTF-8"}):
        probe(cli, daemon_binary, zmx, locale)


if __name__ == "__main__":
    main()
