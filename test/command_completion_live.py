import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import termios
import time
from tmux_exit import wait_for_exit

project, julia = Path(sys.argv[1]).resolve(), sys.argv[2]
mode = sys.argv[3]
socket = f"jf-completion-{os.getpid()}"
tmux = ["tmux", "-f", "/dev/null", "-L", socket]
terminal_fd = None

def run(*args, check=True, env=None):
    return subprocess.run([*tmux, *args], check=check, text=True, capture_output=True, env=env)

def screen():
    return run("capture-pane", "-p", "-J", "-t", "completion").stdout

def wait_for(predicate, label, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = screen()
        if predicate(value):
            return value
        if run("display-message", "-p", "-t", "completion", "#{pane_dead}", check=False).stdout.strip() == "1":
            raise AssertionError(f"{label}: process exited: {value!r}")
        time.sleep(0.05)
    raise AssertionError(f"{label}: {screen()!r}")

def send(text):
    run("send-keys", "-t", "completion", "-l", text)

def key(*keys):
    run("send-keys", "-t", "completion", *keys)

def paste(text):
    data = b"\x1b[200~" + text.encode() + b"\x1b[201~"
    run("send-keys", "-t", "completion", "-H", *(f"{byte:02x}" for byte in data))

def ready(value):
    return "fixture | ready" in value if mode == "fullscreen" else "> " in value

def messages(path):
    try:
        return [json.loads(line) for line in path.read_text().splitlines()]
    except (FileNotFoundError, json.JSONDecodeError):
        return []

def skill(root, name, body, *, hidden=False):
    path = root / ".pi" / "skills" / name / "SKILL.md"
    path.parent.mkdir(parents=True, exist_ok=True)
    explicit = "disable-model-invocation: true\n" if hidden else ""
    path.write_text(f"---\nname: {name}\ndescription: {name} skill\n{explicit}---\n{body}\n")
    return path

def block(path, name, body, args):
    return f'<skill name="{name}" location="{path}">\nReferences are relative to {path.parent}.\n\n{body}\n</skill>\n\n{args}'

try:
    with tempfile.TemporaryDirectory(prefix="jf-completion-") as directory:
        root = Path(directory).resolve()
        prompts = root / ".pi" / "prompts"
        prompts.mkdir(parents=True)
        (prompts / "review.md").write_text("Review $1")
        (prompts / "revise.md").write_text("Revise $1")
        example = skill(root, "example", "Example instructions.")
        skill(root, "reviewer", "Reviewer instructions.", hidden=True)
        (root / "src").mkdir()
        (root / "src" / "main.jl").write_text("fixture")
        (root / "my docs").mkdir()
        (root / "my docs" / "guide.md").write_text("fixture")
        capture = root / "capture.jsonl"
        env = dict(os.environ, HOME=str(root), TERM="xterm-256color", PI_CODING_AGENT_DIR=str(root / "agent"), JF_INSTRUCTIONS_DIR=str(root), JF_SESSION_DIR=str(root / "sessions"), JF_FIXTURE="echo", JF_CAPTURE=str(capture), JF_PROVIDER="openai", OPENAI_MODEL="fixture", OPENAI_API_KEY="synthetic")
        names = ("HOME", "TERM", "PI_CODING_AGENT_DIR", "JF_INSTRUCTIONS_DIR", "JF_SESSION_DIR", "JF_FIXTURE", "JF_CAPTURE", "JF_PROVIDER", "OPENAI_MODEL", "OPENAI_API_KEY", "JULIA_DEPOT_PATH")
        settings = [f"{name}={env[name]}" for name in names if name in env]
        command = shlex.join(["env", *settings, julia, "--startup-file=no", "--compiled-modules=existing", f"--project={project}", str(project / "test/terminal_process.jl"), "--tui-mode", mode, "--no-session"])
        run("new-session", "-d", "-s", "completion", "-x", "100", "-y", "30", "-c", str(root), command, env=env)
        run("set-option", "-t", "completion", "remain-on-exit", "on")
        terminal = run("display-message", "-p", "-t", "completion", "#{pane_tty}").stdout.strip()
        terminal_fd = os.open(terminal, os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
        raw = lambda: not termios.tcgetattr(terminal_fd)[3] & termios.ICANON
        wait_for(lambda s: ready(s) and "> " in s and raw(), "startup", 90)

        send("/rev")
        wait_for(lambda s: "/review" in s and "/revise" in s and "/skill:reviewer" in s, "template and skill suggestions")
        key("Down", "Tab")
        wait_for(lambda s: "> /revise " in s, "selected template")
        send("wolves")
        key("Enter")
        wait_for(lambda s: messages(capture) == ["Revise wolves"] and ready(s), "template request")

        send("/exa")
        wait_for(lambda s: "/skill:example" in s, "bare skill suggestion")
        key("Tab")
        wait_for(lambda s: "> /skill:example " in s, "completed skill")
        send("now")
        key("Enter")
        expected = block(example, "example", "Example instructions.", "now")
        wait_for(lambda s: messages(capture) == ["Revise wolves", expected] and ready(s), "skill request")

        added = skill(root, "fresh", "Fresh instructions.", hidden=True)
        warning = "Wait for the current response to finish before reloading."
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            warnings = screen().count(warning)
            send("/relo")
            wait_for(lambda s: "/reload" in s, "reload suggestion")
            key("Enter")
            result = wait_for(lambda s: "Reloaded skills." in s or s.count(warning) > warnings, "reload result")
            if "Reloaded skills." in result:
                wait_for(lambda s: "> " in s and raw(), "reload prompt")
                break
            time.sleep(0.05)
        else:
            raise AssertionError("reload remained busy")
        send("/fresh")
        wait_for(lambda s: "/skill:fresh" in s, "new hidden skill suggestion")
        key("Tab")
        wait_for(lambda s: "> /skill:fresh " in s, "completed hidden skill")
        send("later")
        key("Enter")
        expected2 = block(added, "fresh", "Fresh instructions.", "later")
        wait_for(lambda s: messages(capture) == ["Revise wolves", expected, expected2] and ready(s), "reloaded skill request")

        send("/revZZ")
        key("Left", "Left")
        wait_for(lambda s: "> /revZZ" in s and "/review" in s, "suggestions at cursor")
        key("Tab")
        send("tail")
        key("Enter")
        wait_for(lambda s: messages(capture)[-1:] == ["Review tailZZ"] and ready(s), "completion preserves text after cursor")

        send("/ne")
        wait_for(lambda s: "/new" in s, "new suggestion")
        key("Escape")
        wait_for(lambda s: "> /ne" in s and "/new" not in s, "dismiss completion")
        send(" text")
        key("Enter")
        wait_for(lambda s: messages(capture)[-1:] == ["/ne text"] and ready(s), "dismissed input")

        paste("/rev")
        wait_for(lambda s: s.rstrip().endswith("> /rev"), "pasted input")
        key("Enter")
        wait_for(lambda s: messages(capture)[-1:] == ["/rev"] and ready(s), "pasted slash stays literal")

        send("read @main")
        wait_for(lambda s: "src/main.jl" in s, "recursive file suggestion")
        key("Tab")
        wait_for(lambda s: "> read @src/main.jl " in s, "completed file reference")
        key("Enter")
        wait_for(lambda s: messages(capture)[-1:] == ["read @src/main.jl"] and ready(s), "file reference request")

        send("open src/main")
        key("Tab")
        wait_for(lambda s: "> open src/main.jl" in s, "direct path completion")
        key("Enter")
        wait_for(lambda s: messages(capture)[-1:] == ["open src/main.jl"] and ready(s), "direct path request")

        send('read @"my d')
        wait_for(lambda s: "my docs/" in s, "quoted directory suggestion")
        key("Tab")
        wait_for(lambda s: '> read @"my docs/"' in s, "completed directory")
        send("gui")
        wait_for(lambda s: "guide.md" in s, "nested file suggestion")
        key("Tab")
        wait_for(lambda s: '> read @"my docs/guide.md" ' in s, "completed quoted file")
        key("Enter")
        wait_for(lambda s: messages(capture)[-1:] == ['read @"my docs/guide.md"'] and ready(s), "quoted file request")

        previous = len(messages(capture))
        send("read @main")
        wait_for(lambda s: "→ main.jl" in s, "enter file suggestion")
        key("Enter")
        wait_for(lambda s: "> read @src/main.jl " in s and len(messages(capture)) == previous, "enter accepts without submitting")
        key("Enter")
        wait_for(lambda s: len(messages(capture)) == previous + 1 and messages(capture)[-1] == "read @src/main.jl" and ready(s), "accepted file request")

        send("read @main")
        wait_for(lambda s: "→ main.jl" in s, "file suggestion before escape")
        key("Escape")
        wait_for(lambda s: "> read @main" in s and "src/main.jl" not in s.split("> read @main")[-1], "dismiss file suggestions")
        key("Enter")
        wait_for(lambda s: messages(capture)[-1:] == ["read @main"] and ready(s), "dismissed file request")

        send("stale @missing")
        key("C-c")
        send("after cancellation")
        key("Enter")
        wait_for(lambda s: messages(capture)[-1:] == ["after cancellation"] and ready(s), "cancel pending file search")
        send("/exit")
        key("Enter")
        status, death_signal = wait_for_exit(run, "completion", seconds=30)
        assert status == "0", (status, death_signal, screen())
    print(f"{mode} command completion passed")
finally:
    if terminal_fd is not None:
        os.close(terminal_fd)
    run("kill-server", check=False)
