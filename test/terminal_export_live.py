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
tmux = ["tmux", "-f", "/dev/null", "-L", f"jf-export-{os.getpid()}"]

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

def launch(name, directory, mode, fixture):
    env = dict(os.environ, TERM="xterm-256color", JF_INSTRUCTIONS_DIR=str(directory), JF_SESSION_DIR=str(directory / "sessions"), JF_FIXTURE=fixture, JF_CAPTURE=str(directory / "capture"), JF_PROVIDER="openai", OPENAI_MODEL="fixture", OPENAI_API_KEY="synthetic")
    keys = ("TERM", "JF_INSTRUCTIONS_DIR", "JF_SESSION_DIR", "JF_FIXTURE", "JF_CAPTURE", "JF_PROVIDER", "OPENAI_MODEL", "OPENAI_API_KEY")
    command = shlex.join(["env", *[f"{key}={env[key]}" for key in keys], julia, "--startup-file=no", "--compiled-modules=existing", f"--project={root}", str(root / "test/terminal_process.jl"), "--tui-mode", mode])
    run("new-session", "-d", "-s", name, "-x", "72", "-y", "24", "-c", str(directory), command, env=env)
    run("set-option", "-t", name, "remain-on-exit", "on")
    wait(name, lambda s: "> " in s, "startup")

def stop(name):
    send(name, "/exit")
    status, signal = wait_for_exit(run, name, seconds=30)
    assert status == "0", (status, signal, screen(name))

def messages(path):
    return [row["message"] for row in map(json.loads, path.read_text().splitlines()) if row["type"] == "message"]

try:
    with tempfile.TemporaryDirectory(prefix="jf-export-live-") as path:
        rootdir = Path(path)
        for mode in ("fullscreen", "regular"):
            directory = rootdir / mode
            directory.mkdir()
            launch(mode, directory, mode, "hold")
            send(mode, "hold")
            wait(mode, lambda s: "Holding" in s, "streaming start")
            output = directory / "during.jsonl"
            send(mode, f"/export {output}")
            wait(mode, lambda s: "Session exported to:" in s and output.exists(), "export while streaming")
            assert [message["role"] for message in messages(output)] == ["user"], messages(output)
            assert len((directory / "capture").read_text().splitlines()) == 1
            (directory / "release").touch()
            wait(mode, lambda s: "reply:hold" in s, "response continued")
            stop(mode)
        directory = rootdir / "branch"
        directory.mkdir()
        launch("branch", directory, "fullscreen", "echo")
        send("branch", "first")
        wait("branch", lambda s: "reply:first" in s and "| ready" in s, "first response")
        send("branch", "second")
        wait("branch", lambda s: "reply:second" in s and "| ready" in s, "second response")
        send("branch", "/tree")
        wait("branch", lambda s: "Session tree" in s, "tree")
        run("send-keys", "-t", "branch", "-l", "reply:first")
        wait("branch", lambda s: "assistant: reply:first" in s, "tree search")
        run("send-keys", "-t", "branch", "Enter")
        wait("branch", lambda s: "reply:first" in s and "reply:second" not in s and "Session tree" not in s and "| ready" in s, "branch selection")
        output = directory / "branch.jsonl"
        send("branch", f"/export {output}")
        wait("branch", lambda s: "Session exported to:" in s and output.exists(), "branch export")
        text = output.read_text()
        assert "reply:first" in text and "reply:second" not in text, text
        stop("branch")
    print("live session export passed")
finally:
    run("kill-server", check=False)
