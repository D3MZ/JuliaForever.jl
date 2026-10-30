import json
import os
import pathlib
import shlex
import subprocess
import sys
import tempfile
import time

root = pathlib.Path(sys.argv[1]).resolve()
julia = sys.argv[2]
socket = f"jf-fork-{os.getpid()}"
tmux = ["tmux", "-f", "/dev/null", "-L", socket]

def run(*args, check=True):
    return subprocess.run([*tmux, *args], check=check, text=True, capture_output=True)

def screen():
    return run("capture-pane", "-p", "-J", "-t", "fork").stdout

def wait_for(predicate, message, seconds=40):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        if run("display-message", "-p", "-t", "fork", "#{pane_dead}", check=False).stdout.strip() == "1":
            if predicate():
                return
            break
        time.sleep(.05)
    raise AssertionError(f"{message}; screen={screen()!r}")

def send(text):
    run("send-keys", "-t", "fork", "-l", text)

def key(*keys):
    run("send-keys", "-t", "fork", *keys)

with tempfile.TemporaryDirectory(prefix="jf-fork-pty-") as temporary:
    workspace = pathlib.Path(temporary)
    requests = workspace / "requests.jsonl"
    sessions = workspace / "sessions"
    env = os.environ.copy()
    env.update(JF_SESSION_REQUESTS=str(requests), JF_SESSION_DIR=str(sessions), JF_PROVIDER="openai", OPENAI_MODEL="fixture", OPENAI_API_KEY="synthetic", TERM="xterm", PI_CODING_AGENT_DIR=str(workspace / "agent"))
    env.pop("JF_SESSION_FAIL", None)
    env.pop("JF_INSTRUCTIONS_DIR", None)
    cmd = [julia, "--startup-file=no", "--compiled-modules=existing", f"--project={root}", str(root / "test/session_cli_process.jl")]
    subprocess.run(cmd, cwd=workspace, env=env, input="first\nsecond\n/exit\n", check=True, capture_output=True, text=True, timeout=90)
    source = next(sessions.glob("*.sqlite"))
    before = source.read_bytes()

    def messages():
        return [json.loads(line) for line in requests.read_text().splitlines()]

    command = shlex.join([*cmd, "--continue"])
    subprocess.run([*tmux, "new-session", "-d", "-s", "fork", "-x", "72", "-y", "24", "-c", str(workspace), command], env=env, check=True, capture_output=True, text=True)
    run("set-option", "-g", "remain-on-exit", "on")
    try:
        wait_for(lambda: "> " in screen(), "editor did not start", 60)
        send("/fork")
        key("Enter")
        wait_for(lambda: "Choose a message" in screen(), "fork selector did not open")
        key("2", "Enter")
        wait_for(lambda: "Forked to new session." in screen() and "> second" in screen(), "selected message was not restored to the editor")
        assert len(messages()) == 2
        send(" revised")
        key("Enter")
        wait_for(lambda: len(messages()) == 3 and "reply:second revised" in screen(), "edited fork was not sent")
        actual = [m["content"] for m in messages()[-1] if m["role"] in ("user", "assistant")]
        assert actual == ["first", "reply:first", "second revised"], actual
        assert source.read_bytes() == before
        send("/exit")
        key("Enter")
        wait_for(lambda: run("display-message", "-p", "-t", "fork", "#{pane_dead}").stdout.strip() == "1", "terminal did not exit")
        assert len(list(sessions.glob("*.sqlite"))) == 2
        print("terminal fork selector, editable draft, and source preservation passed")
    finally:
        run("kill-server", check=False)
