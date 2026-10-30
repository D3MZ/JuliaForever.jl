import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time
from tmux_exit import wait_for_exit
from terminal_pty import Session

root, julia = Path(sys.argv[1]).resolve(), sys.argv[2]
socket = f"jf-markdown-{os.getpid()}"
tmux = ["tmux", "-f", "/dev/null", "-L", socket]

def run(*args, check=True, env=None):
    return subprocess.run([*tmux, *args], check=check, text=True, capture_output=True, env=env)

def screen(name, styled=False):
    args = ["capture-pane", "-p", "-J"]
    if styled:
        args.append("-e")
    return run(*args, "-t", name).stdout

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

def key(name, *keys):
    run("send-keys", "-t", name, *keys)

def launch(name, directory, mode, extra=(), fixture="markdown"):
    env = dict(os.environ, TERM="xterm-256color", JF_INSTRUCTIONS_DIR=str(directory), JF_SESSION_DIR=str(directory / "sessions"), JF_FIXTURE=fixture, JF_PROVIDER="openai", OPENAI_MODEL="fixture", OPENAI_API_KEY="synthetic")
    settings = [f"{name}={env[name]}" for name in ("TERM", "JF_INSTRUCTIONS_DIR", "JF_SESSION_DIR", "JF_FIXTURE", "JF_PROVIDER", "OPENAI_MODEL", "OPENAI_API_KEY")]
    command = shlex.join(["env", *settings, julia, "--startup-file=no", "--compiled-modules=existing", f"--project={root}", str(root / "test/terminal_process.jl"), "--tui-mode", mode, *extra])
    run("new-session", "-d", "-s", name, "-x", "72", "-y", "28", "-c", str(directory), command, env=env)
    run("set-option", "-t", name, "remain-on-exit", "on")
    wait(name, lambda s: "> " in s, "startup")

def stop(name, expected="0"):
    send(name, "/exit")
    key(name, "Enter")
    status, signal = wait_for_exit(run, name, seconds=30)
    assert status == expected, (status, signal, screen(name))

def check(name):
    result = wait(name, lambda s: "Safe  text." in s and "x = 1" in s and "Count" in s and "\x1b[" in screen(name, styled=True), "rendered response")
    assert "Hello bold and italic." in result, result
    assert "**bold**" not in result and "*italic*" not in result, result
    assert "┌" in result and "│ Name" in result, result
    assert "spoof" not in result, result

try:
    with tempfile.TemporaryDirectory(prefix="jf-md-live-") as path:
        base = Path(path)
        for mode in ("fullscreen", "regular"):
            directory = base / mode
            directory.mkdir()
            launch(mode, directory, mode)
            send(mode, "demo")
            key(mode, "Enter")
            wait(mode, lambda s: "Hello **bo" in s, "partial response")
            (directory / "release").touch()
            check(mode)
            if mode == "fullscreen":
                run("resize-window", "-t", mode, "-x", "42", "-y", "20")
                wait(mode, lambda s: "Safe  text." in s and "Count" in s, "resized response")
                key(mode, "C-Home")
                wait(mode, lambda s: "Hello bold and italic." in s, "resized response start")
                key(mode, "C-End")
            stop(mode)
            if mode == "fullscreen":
                launch("reopened", directory, mode, ("--continue",))
                check("reopened")
                stop("reopened")
        failure = base / "failure"
        failure.mkdir()
        launch("failure", failure, "regular", fixture="incomplete")
        send("failure", "demo")
        key("failure", "Enter")
        result = wait("failure", lambda s: "Response incomplete:" in s and "> " in s, "incomplete response")
        assert 0 <= result.index("partial") < result.index("Response incomplete:"), result
        stop("failure", expected="1")
        directory = base / "redirect"
        directory.mkdir()
        (directory / "release").touch()
        session = Session(julia, root, directory, stdout_tty=False, mode="markdown")
        try:
            session.ready()
            os.write(session.master, b"demo\r")
            session.until(lambda: session.stdout.exists() and "Safe " in session.stdout.read_text(), "redirected response", timeout=90)
            result = session.stdout.read_text()
            assert "# Demo\n\nHello **bold** and *italic*." in result, repr(result)
            os.write(session.master, b"/exit\r")
            session.wait_exit()
            assert session.process.returncode == 0
        finally:
            session.close()
    print("streamed Markdown interactions passed")
finally:
    run("kill-server", check=False)
