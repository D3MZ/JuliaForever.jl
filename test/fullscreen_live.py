import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time

root, julia = Path(sys.argv[1]).resolve(), sys.argv[2]
socket = f"jf-screen-{os.getpid()}"
tmux = ["tmux", "-f", "/dev/null", "-L", socket]

def run(*args, check=True, env=None):
    return subprocess.run([*tmux, *args], check=check, text=True, capture_output=True, env=env)

def screen(name):
    return run("capture-pane", "-p", "-J", "-t", name).stdout

def wait_for(name, predicate, label, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = screen(name)
        if predicate(value):
            return value
        if run("display-message", "-p", "-t", name, "#{pane_dead}", check=False).stdout.strip() == "1":
            history = run("capture-pane", "-p", "-J", "-S", "-200", "-t", name).stdout
            raise AssertionError(f"{label}: process exited: {history!r}")
        time.sleep(.1)
    raise AssertionError(f"{label}: {screen(name)!r}")

def send(name, text):
    run("send-keys", "-t", name, "-l", text)

def key(name, *keys):
    run("send-keys", "-t", name, *keys)

def launch(name, directory, mode, extra=()):
    env = dict(os.environ, TERM="xterm-256color", JF_INSTRUCTIONS_DIR=str(directory), JF_SESSION_DIR=str(directory / "sessions"), JF_FIXTURE=mode, JF_CAPTURE=str(directory / "capture.jsonl"), JF_PROVIDER="openai", OPENAI_MODEL="fixture", OPENAI_API_KEY="synthetic-secret")
    settings = [f"{name}={env[name]}" for name in ("TERM", "JF_INSTRUCTIONS_DIR", "JF_SESSION_DIR", "JF_FIXTURE", "JF_CAPTURE", "JF_PROVIDER", "OPENAI_MODEL", "OPENAI_API_KEY")]
    command = shlex.join(["env", *settings, julia, "--startup-file=no", "--compiled-modules=existing", f"--project={root}", str(root / "test/terminal_process.jl"), *extra])
    run("new-session", "-d", "-s", name, "-x", "72", "-y", "16", "-c", str(directory), command, env=env)
    run("set-option", "-t", name, "remain-on-exit", "on")
    wait_for(name, lambda s: "fixture | ready" in s and "> " in s, "startup")

def prompt(name, text, expected):
    send(name, text)
    key(name, "Enter")
    wait_for(name, lambda s: expected in s and "| ready" in s, f"reply {text}")

def stop(name):
    send(name, "/exit")
    key(name, "Enter")
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if run("display-message", "-p", "-t", name, "#{pane_dead}").stdout.strip() == "1":
            assert run("display-message", "-p", "-t", name, "#{pane_dead_status}").stdout.strip() == "0", screen(name)
            return
        time.sleep(.1)
    raise AssertionError(f"{name} did not exit: {screen(name)!r}")

try:
    with tempfile.TemporaryDirectory(prefix="jf-screen-live-") as path:
        directory = Path(path)
        launch("screen", directory, "echo")
        prompt("screen", "wide α界", "reply:wide α界")
        for i in range(10):
            prompt("screen", f"marker-{i:02}", f"reply:marker-{i:02}")
        key("screen", "C-Home")
        wait_for("screen", lambda s: "marker-00" in s and "fixture | ready" in s, "scroll to top")
        key("screen", "C-End")
        wait_for("screen", lambda s: "marker-09" in s and "fixture | ready" in s, "scroll to bottom")
        run("resize-window", "-t", "screen", "-x", "40", "-y", "12")
        wait_for("screen", lambda s: "marker-09" in s and "fixture | ready" in s, "resize")
        run("resize-window", "-t", "screen", "-x", "72", "-y", "16")
        send("screen", "unfinished draft")
        key("screen", "C-l")
        wait_for("screen", lambda s: "Select model" in s and "Enter a model ID" in s, "model menu")
        key("screen", "Down", "Enter")
        wait_for("screen", lambda s: "Model ID" in s, "model input")
        send("screen", "new-model")
        key("screen", "Enter")
        wait_for("screen", lambda s: "new-model | ready" in s and "> unfinished draft" in s, "model change and draft")
        key("screen", "C-u")
        send("screen", "/name Alpha")
        key("screen", "Enter")
        wait_for("screen", lambda s: "Alpha" in s, "name first session")
        send("screen", "/new")
        key("screen", "Enter")
        fresh = wait_for("screen", lambda s: "New session started" in s, "new session")
        assert "marker-09" not in fresh, fresh
        send("screen", "/name Beta")
        key("screen", "Enter")
        wait_for("screen", lambda s: "Beta" in s, "name second session")
        prompt("screen", "second session", "reply:second session")
        send("screen", "/resume")
        key("screen", "Enter")
        wait_for("screen", lambda s: "Resume session" in s and "Alpha" in s, "session menu")
        send("screen", "Alpha")
        key("screen", "Enter")
        restored = wait_for("screen", lambda s: "Resuming session" in s and "| Alpha |" in s and "reply:marker-09" in s, "resume session")
        assert "reply:second session" not in restored, restored
        send("screen", "/tree")
        key("screen", "Enter")
        wait_for("screen", lambda s: "Session tree" in s, "tree menu")
        send("screen", "reply:marker-04")
        wait_for("screen", lambda s: "assistant: reply:marker-04" in s, "tree search")
        key("screen", "Enter")
        branch = wait_for("screen", lambda s: "| Alpha |" in s and "reply:marker-04" in s and "> " in s, "tree selection")
        assert "reply:marker-09" not in branch, branch
        prompt("screen", "branch", "reply:branch")
        send("screen", "/fork")
        key("screen", "Enter")
        wait_for("screen", lambda s: "Fork session" in s, "fork menu")
        send("screen", "branch")
        wait_for("screen", lambda s: "> branch" in s, "fork search")
        key("screen", "Enter")
        wait_for("screen", lambda s: "Forked to new session" in s and "> branch" in s, "fork draft")
        key("screen", "C-u")
        prompt("screen", "forked", "reply:forked")
        stop("screen")
        tool_dir = directory / "tool"
        tool_dir.mkdir()
        launch("tool", tool_dir, "tool")
        prompt("tool", "inspect", "after")
        wait_for("tool", lambda s: "[tool] read: error" in s, "tool status")
        key("tool", "C-o")
        expanded = wait_for("tool", lambda s: "arguments:" in s and "[redacted]" in s, "tool details")
        assert "synthetic-secret" not in expanded, expanded
        stop("tool")
        launch("reopened", tool_dir, "tool", ("--continue",))
        wait_for("reopened", lambda s: "[tool] read: error" in s, "reopened tool")
        key("reopened", "C-o")
        expanded = wait_for("reopened", lambda s: "arguments:" in s and "[redacted]" in s, "reopened tool details")
        assert "synthetic-secret" not in expanded, expanded
        stop("reopened")
        hold_dir = directory / "hold"
        hold_dir.mkdir()
        launch("hold", hold_dir, "hold")
        send("hold", "hold")
        key("hold", "Enter")
        wait_for("hold", lambda s: "Holding" in s and "| working" in s, "streaming")
        send("hold", "steering")
        key("hold", "Enter")
        wait_for("hold", lambda s: "Steering: steering" in s, "queued steering", timeout=4)
        send("hold", "follow-up")
        key("hold", "C-q")
        wait_for("hold", lambda s: "Follow-up: follow-up" in s, "queued follow-up", timeout=4)
        key("hold", "Escape")
        wait_for("hold", lambda s: "steering" in s and "follow-up" in s and "Steering: steering" not in s, "restored queues")
        (hold_dir / "release").touch()
        key("hold", "C-c")
        stop("hold")
    print("fullscreen interaction passed")
finally:
    run("kill-server", check=False)
