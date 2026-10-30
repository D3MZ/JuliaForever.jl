import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import termios
import time
from tmux_exit import wait_for_exit

project, julia, mode = Path(sys.argv[1]).resolve(), sys.argv[2], sys.argv[3]
tmux = ["tmux", "-f", "/dev/null", "-L", f"jf-prompt-history-{os.getpid()}"]
terminal_fd = None

def run(*args, check=True, env=None):
    return subprocess.run([*tmux, *args], check=check, text=True, capture_output=True, env=env)

def screen():
    return run("capture-pane", "-p", "-J", "-t", "history").stdout

def wait_for(predicate, label, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = screen()
        if predicate(value):
            return value
        if run("display-message", "-p", "-t", "history", "#{pane_dead}", check=False).stdout.strip() == "1":
            raise AssertionError(f"{label}: process exited: {value!r}")
        time.sleep(.05)
    raise AssertionError(f"{label}: {screen()!r}")

def prompt(value):
    return next((line[2:] for line in reversed(value.splitlines()) if line.startswith("> ")), None)

def ready(value):
    raw = terminal_fd is not None and not termios.tcgetattr(terminal_fd)[3] & termios.ICANON
    return raw and prompt(value) is not None and (mode == "regular" or " | ready" in value)

def send(text):
    run("send-keys", "-t", "history", "-l", text)

def key(*keys):
    run("send-keys", "-t", "history", *keys)

def records(path):
    try:
        return [json.loads(line) for line in path.read_text().splitlines()]
    except (FileNotFoundError, json.JSONDecodeError):
        return []

def endings(path):
    try:
        return path.read_text().splitlines().count("agent_end")
    except FileNotFoundError:
        return 0

def request(path, events, text):
    count = len(records(path))
    completed = endings(events)
    send(text)
    key("Enter")
    wait_for(lambda s: len(records(path)) == count + 1 and records(path)[-1] == text and endings(events) == completed + 1 and f"reply:{text}" in s and ready(s), f"request {text}")

def exit_session():
    global terminal_fd
    send("/exit")
    key("Enter")
    status, signal = wait_for_exit(run, "history", seconds=30)
    assert status == "0", (status, signal, screen())
    run("kill-session", "-t", "history")
    os.close(terminal_fd)
    terminal_fd = None

try:
    with tempfile.TemporaryDirectory(prefix="jf-prompt-history-") as temporary:
        root = Path(temporary).resolve()
        capture = root / "capture.jsonl"
        events = root / "events"
        env = dict(os.environ, HOME=str(root), TERM="xterm-256color", PI_CODING_AGENT_DIR=str(root / "agent"), JF_INSTRUCTIONS_DIR=str(root), JF_SESSION_DIR=str(root / "sessions"), JF_FIXTURE="echo", JF_CAPTURE=str(capture), JF_TEST_EVENTS=str(events), JF_PROVIDER="openai", OPENAI_MODEL="fixture", OPENAI_API_KEY="synthetic")
        names = ("HOME", "TERM", "PI_CODING_AGENT_DIR", "JF_INSTRUCTIONS_DIR", "JF_SESSION_DIR", "JF_FIXTURE", "JF_CAPTURE", "JF_TEST_EVENTS", "JF_PROVIDER", "OPENAI_MODEL", "OPENAI_API_KEY", "JULIA_DEPOT_PATH")
        settings = [f"{name}={env[name]}" for name in names if name in env]

        def launch(*options):
            global terminal_fd
            command = shlex.join(["env", *settings, julia, "--startup-file=no", "--compiled-modules=existing", f"--project={project}", str(project / "test/terminal_process.jl"), "--plugin-env", str(project / "test/fixtures"), "--plugin", "GreetingPlugin", "--tui-mode", mode, *options])
            run("new-session", "-d", "-s", "history", "-x", "100", "-y", "30", "-c", str(root), command, env=env)
            run("set-option", "-t", "history", "remain-on-exit", "on")
            terminal = run("display-message", "-p", "-t", "history", "#{pane_tty}").stdout.strip()
            terminal_fd = os.open(terminal, os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
            wait_for(ready, "startup", timeout=90)

        launch("--name", "Alpha")
        request(capture, events, "alpha")
        request(capture, events, "beta")
        send("/name Alpha")
        key("Enter")
        wait_for(lambda s: "Session name set: Alpha" in s and ready(s), "name session")
        key("Up")
        wait_for(lambda s: prompt(s) == "beta", "commands stay out of prompt history")
        key("C-c")
        exit_session()

        launch("--continue")
        key("Up")
        wait_for(lambda s: prompt(s) == "beta", "latest restored prompt")
        key("Up")
        wait_for(lambda s: prompt(s) == "alpha", "earlier restored prompt")
        key("Down")
        wait_for(lambda s: prompt(s) == "beta", "later restored prompt")
        key("Down")
        wait_for(lambda s: prompt(s) == "", "restore empty draft")

        send("/new")
        key("Enter")
        wait_for(lambda s: "New session started" in s and ready(s), "new session")
        key("Up")
        wait_for(lambda s: prompt(s) == "beta", "new session retains editor history")
        key("C-c")
        request(capture, events, "gamma")
        send("/resume")
        key("Enter")
        if mode == "fullscreen":
            wait_for(lambda s: "Resume session" in s and "Alpha" in s, "resume selector")
            send("Alpha")
            key("Enter")
        else:
            selected = wait_for(lambda s: "Choose a session" in s and "Alpha" in s, "resume selector")
            match = re.search(r"\[(\d+)\][^\n]*Alpha", selected)
            assert match, selected
            send(match.group(1))
            key("Enter")
        wait_for(lambda s: "Resuming session" in s and ready(s), "resumed session")
        key("Up")
        wait_for(lambda s: prompt(s) == "beta", "resumed session prompt")
        key("C-c")
        send("/tree")
        key("Enter")
        if mode == "fullscreen":
            wait_for(lambda s: "Session tree" in s, "tree selector")
            send("reply:alpha")
            wait_for(lambda s: "assistant: reply:alpha" in s, "tree search")
            key("Enter")
            wait_for(lambda s: "Session tree" not in s and "reply:alpha" in s and ready(s), "selected branch")
        else:
            wait_for(lambda s: "Choose a message" in s and "reply:alpha" in s, "tree selector")
            send("2")
            key("Enter")
            wait_for(lambda s: s.rfind("> ") > s.rfind("Choose a message") and ready(s), "selected branch")
        key("Up")
        wait_for(lambda s: prompt(s) == "alpha", "selected branch prompt")
        key("C-c")
        exit_session()

        explicit = root / "explicit.sqlite"
        launch("--history", str(explicit))
        request(capture, events, "explicit history")
        exit_session()
        launch("--history", str(explicit))
        key("Up")
        wait_for(lambda s: prompt(s) == "explicit history", "explicit history prompt")
        key("C-c")
        exit_session()
    print(f"{mode} restored prompt history passed")
finally:
    if terminal_fd is not None:
        os.close(terminal_fd)
    run("kill-server", check=False)
