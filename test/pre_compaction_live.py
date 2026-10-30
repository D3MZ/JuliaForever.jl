import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time
from tmux_exit import wait_for_exit

project, julia = Path(sys.argv[1]).resolve(), sys.argv[2]
tmux = ["tmux", "-f", "/dev/null", "-L", f"jf-pre-compact-{os.getpid()}"]

def run(*args, check=True, env=None):
    return subprocess.run([*tmux, *args], check=check, text=True, capture_output=True, env=env)

def screen():
    return run("capture-pane", "-p", "-J", "-t", "pre").stdout

def wait(predicate, label, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        text = screen()
        if predicate(text):
            return text
        if run("display-message", "-p", "-t", "pre", "#{pane_dead}", check=False).stdout.strip() == "1":
            raise AssertionError(f"{label}: process exited: {text!r}")
        time.sleep(.1)
    raise AssertionError(f"{label}: {screen()!r}")

def send(text):
    run("send-keys", "-t", "pre", "-l", text)
    run("send-keys", "-t", "pre", "Enter")

def calls(path):
    try:
        return [json.loads(line) for line in path.read_text().splitlines()]
    except (FileNotFoundError, json.JSONDecodeError):
        return []

try:
    with tempfile.TemporaryDirectory(prefix="jf-pre-compact-live-") as path:
        directory = Path(path)
        agent = directory / "agent"
        agent.mkdir()
        model = {"id": "small", "name": "Small", "contextWindow": 16514, "maxTokens": 64}
        (agent / "models.json").write_text(json.dumps({"providers": {"fixture": {"api": "openai-completions", "apiKey": "fixture", "baseUrl": "http://localhost", "models": [model]}}}))
        settings = agent / "settings.json"
        settings.write_text(json.dumps({"compaction": {"enabled": False, "keepRecentTokens": 0}}))
        history, requests, gate = directory / "history.sqlite", directory / "requests", directory / "gate"
        env = dict(os.environ, HOME=str(directory), TERM="xterm-256color", PI_CODING_AGENT_DIR=str(agent), JF_INSTRUCTIONS_DIR=str(directory), JF_SESSION_DIR=str(directory / "sessions"), JF_AUTO_REQUESTS=str(requests), JF_AUTO_GATE=str(gate), JF_AUTO_SUMMARY="")
        args = [julia, "--startup-file=no", "--compiled-modules=existing", f"--project={project}", str(project / "test/terminal_auto_compaction_process.jl"), "--history", str(history), "--provider", "fixture", "--model", "small"]
        seed = subprocess.run(args, cwd=directory, env=env, input="first\nsecond\n/exit\n", capture_output=True, text=True, timeout=90)
        assert seed.returncode == 0, (seed.stdout, seed.stderr)
        settings.write_text(json.dumps({"compaction": {"enabled": True, "keepRecentTokens": 0}}))
        keys = ("HOME", "TERM", "PI_CODING_AGENT_DIR", "JF_INSTRUCTIONS_DIR", "JF_SESSION_DIR", "JF_AUTO_REQUESTS", "JF_AUTO_GATE", "JF_AUTO_SUMMARY")
        command = shlex.join(["env", *[f"{key}={env[key]}" for key in keys], *args, "--tui-mode", "fullscreen"])
        run("new-session", "-d", "-s", "pre", "-x", "90", "-y", "30", "-c", str(directory), command, env=env)
        run("set-option", "-t", "pre", "remain-on-exit", "on")
        wait(lambda s: "small | ready" in s and "> " in s, "startup")
        send("third")
        wait(lambda s: "Auto-compaction started." in s and "| working" in s and len(calls(requests)) == 3, "pre-prompt compaction")
        before = calls(requests)
        assert [call["operation"] for call in before] == ["respond", "respond", "summarize"], before
        send("queued")
        wait(lambda s: "Steering: queued" in s, "queued prompt")
        gate.touch()
        wait(lambda s: "[summary] checkpoint" in s and "reply:third" in s, "reopened response")
        wait(lambda s: "reply:queued" in s and "| ready" in s, "queued response")
        after = calls(requests)
        assert [call["operation"] for call in after] == ["respond", "respond", "summarize", "respond", "respond"], after
        assert "checkpoint" in json.dumps(after[3]["messages"]), after[3]
        send("/exit")
        status, signal = wait_for_exit(run, "pre", seconds=30)
        assert status == "0", (status, signal, screen())
    print("interactive pre-prompt compaction and queue passed")
finally:
    run("kill-server", check=False)
