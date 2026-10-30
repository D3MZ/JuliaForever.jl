import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import termios
import time
from tmux_exit import wait_for_exit

root, julia = Path(sys.argv[1]).resolve(), sys.argv[2]
tmux = ["tmux", "-f", "/dev/null", "-L", f"jf-session-info-{os.getpid()}"]

def run(*args, check=True, env=None):
    return subprocess.run([*tmux, *args], check=check, text=True, capture_output=True, env=env)

def screen(name):
    return run("capture-pane", "-p", "-J", "-t", name).stdout

def raw(name):
    terminal = run("display-message", "-p", "-t", name, "#{pane_tty}").stdout.strip()
    fd = os.open(terminal, os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        return not termios.tcgetattr(fd)[3] & termios.ICANON
    finally:
        os.close(fd)

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

def launch(name, directory, fixture):
    env = dict(os.environ, TERM="xterm-256color", JF_INSTRUCTIONS_DIR=str(directory), JF_SESSION_DIR=str(directory / "sessions"), JF_FIXTURE=fixture, JF_CAPTURE=str(directory / "capture"), JF_PROVIDER="openai", OPENAI_MODEL="fixture", OPENAI_API_KEY="synthetic")
    keys = ("TERM", "JF_INSTRUCTIONS_DIR", "JF_SESSION_DIR", "JF_FIXTURE", "JF_CAPTURE", "JF_PROVIDER", "OPENAI_MODEL", "OPENAI_API_KEY")
    command = shlex.join(["env", *[f"{key}={env[key]}" for key in keys], julia, "--startup-file=no", "--compiled-modules=existing", f"--project={root}", str(root / "test/terminal_process.jl"), "--tui-mode", "fullscreen"])
    run("new-session", "-d", "-s", name, "-x", "72", "-y", "36", "-c", str(directory), command, env=env)
    run("set-option", "-t", name, "remain-on-exit", "on")
    wait(name, lambda s: "| ready" in s and "> " in s, "startup")

def stop(name):
    send(name, "/exit")
    status, signal = wait_for_exit(run, name, seconds=30)
    assert status == "0", (status, signal, screen(name))

try:
    with tempfile.TemporaryDirectory(prefix="jf-session-info-") as path:
        rootdir = Path(path)
        branch = rootdir / "branch"
        branch.mkdir()
        launch("branch", branch, "usage")
        send("branch", "first")
        wait("branch", lambda s: "reply:first" in s and "| ready" in s, "first response")
        send("branch", "second")
        wait("branch", lambda s: "reply:second" in s and "| ready" in s, "second response")
        send("branch", "/tree")
        wait("branch", lambda s: "Session tree" in s, "tree")
        run("send-keys", "-t", "branch", "-l", "reply:first")
        wait("branch", lambda s: "assistant: reply:first" in s, "tree search")
        run("send-keys", "-t", "branch", "Enter")
        wait("branch", lambda s: "reply:first" in s and "reply:second" not in s and "Session tree" not in s and "| ready" in s and raw("branch"), "branch selection")
        send("branch", "/session")
        summary = wait("branch", lambda s: "Session Info" in s and "Total: 225" in s, "session statistics")
        assert "User: 2" in summary and "Assistant: 2" in summary and "$0.015" in summary, summary
        stop("branch")
        busy = rootdir / "busy"
        busy.mkdir()
        launch("busy", busy, "hold")
        send("busy", "hold")
        wait("busy", lambda s: "Holding" in s and "| working" in s, "streaming")
        send("busy", "/session")
        summary = wait("busy", lambda s: "Session Info" in s and "User: 1" in s and "| working" in s, "session while streaming")
        assert "Assistant: 0" in summary, summary
        (busy / "release").touch()
        wait("busy", lambda s: "reply:hold" in s and "| ready" in s, "response continued")
        stop("busy")
    print("live session information passed")
finally:
    run("kill-server", check=False)
