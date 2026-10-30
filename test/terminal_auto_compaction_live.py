import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time
from tmux_exit import wait_for_exit

root, julia = Path(sys.argv[1]).resolve(), sys.argv[2]
tmux = ["tmux", "-f", "/dev/null", "-L", f"jf-auto-compact-{os.getpid()}"]

def run(*args, check=True, env=None):
    return subprocess.run([*tmux, *args], check=check, text=True, capture_output=True, env=env)

def screen(name):
    return run("capture-pane", "-p", "-J", "-t", name).stdout

def wait(name, predicate, label, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        text = screen(name)
        if predicate(text):
            return text
        if run("display-message", "-p", "-t", name, "#{pane_dead}", check=False).stdout.strip() == "1":
            raise AssertionError(f"{label}: process exited: {text!r}")
        time.sleep(.1)
    raise AssertionError(f"{label}: {screen(name)!r}")

def send(name, text):
    run("send-keys", "-t", name, "-l", text)
    run("send-keys", "-t", name, "Enter")

def calls(path):
    return [json.loads(line) for line in path.read_text().splitlines()]

def launch(name, directory):
    agent = directory / "agent"
    agent.mkdir()
    model = {"id": "small", "name": "Small", "contextWindow": 16514, "maxTokens": 64}
    (agent / "models.json").write_text(json.dumps({"providers": {"fixture": {"api": "openai-completions", "apiKey": "fixture", "baseUrl": "http://localhost", "models": [model]}}}))
    (agent / "settings.json").write_text(json.dumps({"compaction": {"keepRecentTokens": 0}}))
    env = dict(os.environ, HOME=str(directory), TERM="xterm-256color", PI_CODING_AGENT_DIR=str(agent), JF_INSTRUCTIONS_DIR=str(directory), JF_SESSION_DIR=str(directory / "sessions"), JF_AUTO_REQUESTS=str(directory / "requests"), JF_AUTO_GATE=str(directory / "gate"), JF_AUTO_SUMMARY="")
    keys = ("HOME", "TERM", "PI_CODING_AGENT_DIR", "JF_INSTRUCTIONS_DIR", "JF_SESSION_DIR", "JF_AUTO_REQUESTS", "JF_AUTO_GATE", "JF_AUTO_SUMMARY")
    command = shlex.join(["env", *[f"{key}={env[key]}" for key in keys], julia, "--startup-file=no", "--compiled-modules=existing", f"--project={root}", str(root / "test/terminal_auto_compaction_process.jl"), "--provider", "fixture", "--model", "small", "--tui-mode", "fullscreen"])
    run("new-session", "-d", "-s", name, "-x", "90", "-y", "30", "-c", str(directory), command, env=env)
    run("set-option", "-t", name, "remain-on-exit", "on")
    wait(name, lambda s: "small | ready" in s and "> " in s, "startup")

def stop(name):
    send(name, "/exit")
    status, signal = wait_for_exit(run, name, seconds=30)
    assert status == "0", (status, signal, screen(name))

try:
    with tempfile.TemporaryDirectory(prefix="jf-auto-compact-live-") as path:
        for cancelled in (False, True):
            name = "cancelled" if cancelled else "completed"
            directory = Path(path) / name
            directory.mkdir()
            launch(name, directory)
            send(name, "first")
            wait(name, lambda s: "reply:first" in s and "| ready" in s, "first")
            send(name, "second")
            wait(name, lambda s: "Auto-compaction started." in s and "| working" in s, "compaction")
            send(name, "queued")
            wait(name, lambda s: "Steering: queued" in s, "queued during compaction")
            if cancelled:
                run("send-keys", "-t", name, "Escape")
                wait(name, lambda s: "> queued" in s, "restored queued prompt")
            (directory / "gate").touch()
            if cancelled:
                wait(name, lambda s: "Auto-compaction cancelled." in s and "| ready" in s, "cancelled compaction")
                run("send-keys", "-t", name, "Enter")
            else:
                wait(name, lambda s: "[summary] checkpoint" in s and "Auto-compaction complete." in s, "compacted transcript", timeout=6)
            wait(name, lambda s: "reply:queued" in s and "| ready" in s, "queued response")
            messages = calls(directory / "requests")[-1]["messages"]
            contents = json.dumps(messages)
            assert ("checkpoint" in contents) is not cancelled, contents
            if cancelled:
                assert "reply:first" in contents and "reply:second" in contents, contents
            stop(name)
    print("interactive auto-compaction queue and cancellation passed")
finally:
    run("kill-server", check=False)
