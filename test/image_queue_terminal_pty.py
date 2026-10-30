import json
import os
import pathlib
import shlex
import subprocess
import sys
import tempfile
import time

from tmux_exit import wait_for_exit

root = pathlib.Path(sys.argv[1]).resolve()
julia = sys.argv[2]
socket = f"jf-image-queue-{os.getpid()}"
tmux = ["tmux", "-f", "/dev/null", "-L", socket]

def run(*args, check=True):
    return subprocess.run([*tmux, *args], check=check, text=True, capture_output=True, timeout=20)

def history():
    return run("capture-pane", "-p", "-J", "-S", "-200", "-t", "image").stdout

def prompt_ready(text=""):
    return history().rstrip().endswith(">" + (" " + text if text else ""))

def wait_for(predicate, label, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        if run("display-message", "-p", "-t", "image", "#{pane_dead}", check=False).stdout.strip() == "1":
            raise AssertionError(f"terminal exited during {label}: {history()!r}")
        time.sleep(0.05)
    raise AssertionError(f"{label}: {history()!r}")

def key(*keys):
    run("send-keys", "-t", "image", *keys)

def send(text):
    run("send-keys", "-t", "image", "-l", text)

def check_report(directory, mode):
    report = json.loads((directory / "report.json").read_text())
    assert report["status"] == (1 if mode == "failure" else 0), report
    assert report["calls"] == 1, report
    assert report["steering"][0] == "text steering", report
    assert report["steering"][1] == {"role": "user", "content": "image steering", "images": [{"mime": "image/png", "data": "c3ludGhldGljLWltYWdl"}]}, report
    assert report["followups"][0] == {"role": "user", "content": "image followup", "images": [{"mime": "image/png", "data": "c3ludGhldGljLWltYWdl"}]}, report
    assert report["followups"][1] == "text followup", report
    assert "Dequeue" not in report["events"], report

try:
    for view, mode in (("regular", "cancel"), ("regular", "failure"), ("fullscreen", "cancel")):
        with tempfile.TemporaryDirectory(prefix="jf-image-queue-") as temporary:
            directory = pathlib.Path(temporary)
            command = shlex.join([julia, "--startup-file=no", "--compiled-modules=existing", f"--project={root}", str(root / "test" / "image_queue_terminal_fixture.jl"), str(directory), mode, view])
            subprocess.run([*tmux, "new-session", "-d", "-s", "image", "-x", "100", "-y", "30", "-c", temporary, command], check=True, capture_output=True, text=True, timeout=20)
            run("set-option", "-g", "remain-on-exit", "on")
            wait_for(lambda: "> " in history(), "editor startup", 60)
            send("start")
            key("Enter")
            wait_for(lambda: (directory / "started").exists() and "Steering: image steering" in history(), "image queue", 30)
            if mode == "cancel":
                send("draft")
                key("M-Up")
                wait_for(lambda: "Queued images cannot be restored" in history() and prompt_ready("draft"), "Alt-Up refusal")
                assert "Steering: image steering" in history() and "> draft" in history(), history()
                key("C-c")
                for command_name in ("/new", "/fork", "/resume", "/tree", "/clone"):
                    before = history().count("Queued images cannot be restored")
                    send(command_name)
                    key("Enter")
                    wait_for(lambda: history().count("Queued images cannot be restored") > before and prompt_ready(command_name), f"{command_name} refusal")
                    assert not (directory / "provider_finished").exists(), history()
                    key("C-c")
                send("draft")
                key("Escape")
                wait_for(lambda: "Request cancelled." in history() and prompt_ready("draft"), "cancellation")
                key("C-c")
            else:
                (directory / "release").write_text("go")
                wait_for(lambda: "Response incomplete" in history() and "Queued images cannot be restored" in history() and prompt_ready(), "failure recovery")
                before = history().count("Queued images cannot be restored")
                key("M-Up")
                wait_for(lambda: history().count("Queued images cannot be restored") > before and prompt_ready(), "idle Alt-Up refusal")
                for command_name in ("/new", "/fork", "/resume"):
                    before = history().count("History has unprocessed queued messages")
                    send(command_name)
                    key("Enter")
                    wait_for(lambda: history().count("History has unprocessed queued messages") > before and prompt_ready(), f"idle {command_name} refusal")
            send("/exit")
            key("Enter")
            status, death_signal = wait_for_exit(run, "image", seconds=30)
            assert status == "0", (status, death_signal, history())
            check_report(directory, mode)
            run("kill-session", "-t", "image", check=False)
    print("image queues survive terminal recovery and session commands")
finally:
    run("kill-server", check=False)
