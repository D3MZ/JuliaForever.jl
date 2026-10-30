import json
import os
import pathlib
import shlex
import signal
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from tmux_exit import wait_for_exit

root = pathlib.Path(sys.argv[1]).resolve()
julia = sys.argv[2]
more = threading.Event()
finish = threading.Event()
stop_finish = threading.Event()
recover_finish = threading.Event()
headers_finish = threading.Event()
failure_finish = threading.Event()
new_finish = threading.Event()
fork_finish = threading.Event()
requests = []
requests_lock = threading.Lock()

class Server(ThreadingHTTPServer):
    daemon_threads = True

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *_):
        pass

    def event(self, data):
        self.chunk(b"data: " + json.dumps(data).encode() + b"\n\n")

    def chunk(self, data):
        self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
        self.wfile.flush()

    def do_POST(self):
        data = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with requests_lock:
            requests.append(data["messages"])
            index = len(requests)
        try:
            if index == 9:
                headers_finish.wait(30)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Connection", "close")
            self.close_connection = True
            self.end_headers()
            if index == 12:
                command = "printf '%s' \"$$\" > shell.pid; printf running > shell.state; sleep 30; printf completed > shell.state"
                call = {"index": 0, "id": "shell", "type": "function", "function": {"name": "bash", "arguments": json.dumps({"command": command})}}
                self.event({"choices": [{"index": 0, "delta": {"tool_calls": [call]}}]})
                self.event({"choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]})
                self.chunk(b"data: [DONE]\n\n")
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
                return
            text = {1: "First", 2: "Steered", 3: "Followed", 4: "Stopping", 5: "Resumed", 6: "Hold", 7: "Retrieved", 8: "Reopened", 10: "Failing", 11: "Recovered", 13: "After shell", 14: "Before new", 15: "New session", 16: "Before fork", 17: "Fork response"}.get(index, "Unexpected")
            self.event({"choices": [{"index": 0, "delta": {"content": text}}]})
            if index == 1:
                more.wait(30)
                self.event({"choices": [{"index": 0, "delta": {"content": " response " + "x" * 70}}]})
                finish.wait(30)
            elif index == 4:
                stop_finish.wait(30)
            elif index == 6:
                recover_finish.wait(30)
            elif index == 10:
                failure_finish.wait(30)
            elif index == 14:
                new_finish.wait(30)
            elif index == 16:
                fork_finish.wait(30)
            reason = "content_filter" if index == 10 else "stop"
            self.event({"choices": [{"index": 0, "delta": {}, "finish_reason": reason}]})
            self.chunk(b"data: [DONE]\n\n")
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

server = Server(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
socket = f"jf-live-{os.getpid()}"
tmux = ["tmux", "-f", "/dev/null", "-L", socket]

def run(*args, check=True):
    return subprocess.run([*tmux, *args], check=check, text=True, capture_output=True)

def screen():
    return run("capture-pane", "-p", "-J", "-t", "live").stdout

def history():
    return run("capture-pane", "-p", "-J", "-S", "-200", "-t", "live").stdout

def wait_for(predicate, message, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        if run("display-message", "-p", "-t", "live", "#{pane_dead}", check=False).stdout.strip() == "1":
            if predicate():
                return
            raise AssertionError(f"terminal exited; screen={history()!r}; requests={requests!r}")
        time.sleep(.05)
    raise AssertionError(f"{message}; screen={screen()!r}; requests={requests!r}")

def send(text):
    run("send-keys", "-t", "live", "-l", text)

def key(*keys):
    run("send-keys", "-t", "live", *keys)

with tempfile.TemporaryDirectory(prefix="jf-live-pty-") as directory:
    pidfile = pathlib.Path(directory) / "shell.pid"
    shell_reaped = False
    prompts = pathlib.Path(directory) / ".pi" / "prompts"
    prompts.mkdir(parents=True)
    (prompts / "qfollow.md").write_text("expanded $1")
    env = os.environ.copy()
    env.update(JF_PROVIDER="openai", OPENAI_MODEL="fixture", OPENAI_API_KEY="synthetic", OPENAI_BASE_URL=f"http://127.0.0.1:{server.server_port}/v1", JF_SESSION_DIR=directory, PI_CODING_AGENT_DIR=str(pathlib.Path(directory) / "agent"))
    env.pop("JF_INSTRUCTIONS_DIR", None)
    command = shlex.join([julia, "--startup-file=no", "--compiled-modules=existing", f"--project={root}", "-e", "using JuliaForever; exit(JuliaForever.main(ARGS))", "--", "--tui-mode", "regular"])
    subprocess.run([*tmux, "new-session", "-d", "-s", "live", "-x", "72", "-y", "24", "-c", directory, command], env=env, check=True, capture_output=True, text=True)
    run("set-option", "-g", "remain-on-exit", "on")
    try:
        wait_for(lambda: "> " in screen(), "editor failed to start", 60)
        key("M-Up")
        send("probe")
        wait_for(lambda: "> probe" in screen(), "empty dequeue did not return to the editor", 8)
        assert not list(pathlib.Path(directory).glob("*.sqlite"))
        key("C-c")
        send("first")
        key("Enter")
        wait_for(lambda: len(requests) == 1 and "First" in screen(), "first response did not stream", 30)
        send("/name Live Session")
        key("Enter")
        wait_for(lambda: "Session name set: Live Session" in screen(), "naming did not work during streaming", 8)
        assert len(requests) == 1 and not finish.is_set()
        run("resize-window", "-t", "live", "-x", "30", "-y", "12")
        send("discard")
        key("C-c")
        send("steer")
        more.set()
        wait_for(lambda: "First response" + "x" * 70 in screen().replace("\n", "") and "> steer" in screen(), "streaming or resize overwrote the draft", 8)
        run("resize-window", "-t", "live", "-x", "72", "-y", "24")
        key("Enter")
        wait_for(lambda: "Steering: steer" in screen(), "steering was not queued during the request", 8)
        send("/qfollow value")
        key("M-Enter")
        wait_for(lambda: "Follow-up: expanded value" in screen(), "expanded follow-up was not queued during the request", 8)
        assert len(requests) == 1, requests
        finish.set()
        wait_for(lambda: len(requests) >= 3 and "Followed" in screen(), "queued turns did not finish", 30)
        users = [[m["content"] for m in request if m["role"] == "user"] for request in requests[:3]]
        assert users == [["first"], ["first", "steer"], ["first", "steer", "expanded value"]], users
        send("stop")
        key("Enter")
        wait_for(lambda: len(requests) >= 4 and "Stopping" in screen(), "stop request did not start", 15)
        send("queued")
        key("Enter")
        wait_for(lambda: "Steering: queued" in screen(), "stop request did not queue steering", 8)
        send("current")
        key("Escape")
        wait_for(lambda: "Request cancelled." in screen() and "queued" in screen() and "current" in screen(), "escape did not cancel and restore queued messages", 8)
        assert not stop_finish.is_set()
        key("Enter")
        wait_for(lambda: len(requests) >= 5 and "Resumed" in screen(), "restored message was not sent", 15)
        assert [m["content"] for m in requests[4] if m["role"] == "user"][-1] == "queued\n\ncurrent", requests[4]
        send("inspect")
        key("Enter")
        wait_for(lambda: len(requests) >= 6 and "Hold" in screen(), "dequeue request did not start", 15)
        send("another")
        key("Enter")
        wait_for(lambda: "Steering: another" in screen(), "dequeue steering was not queued", 8)
        send("after")
        key("M-Enter")
        wait_for(lambda: "Follow-up: after" in screen(), "dequeue follow-up was not queued", 8)
        send("current")
        key("M-Up")
        wait_for(lambda: all(item in screen() for item in ("another", "after", "current")) and "Steering: another" not in screen() and "Follow-up: after" not in screen(), "Alt-Up did not restore queued messages", 8)
        key("Enter")
        wait_for(lambda: "Steering: another" in screen(), "restored messages were not requeued", 8)
        recover_finish.set()
        wait_for(lambda: len(requests) >= 7 and "Retrieved" in screen(), "restored messages were not delivered", 15)
        assert [m["content"] for m in requests[6] if m["role"] == "user"][-1] == "another\n\nafter\n\ncurrent", requests[6]
        send("/exit")
        key("Enter")
        status, death_signal = wait_for_exit(run, "live")
        assert status == "0", f"exit status={status!r}; signal={death_signal!r}; screen={history()!r}"
        assert len(list(pathlib.Path(directory).glob("*.sqlite"))) == 1
        resumed = shlex.join([julia, "--startup-file=no", "--compiled-modules=existing", f"--project={root}", "-e", "using JuliaForever; exit(JuliaForever.main(ARGS))", "--", "--tui-mode", "regular", "--continue"])
        run("new-window", "-t", "live", "-n", "resumed", "-c", directory, resumed)
        wait_for(lambda: "> " in screen(), "saved session did not reopen", 60)
        send("reopen")
        key("Enter")
        wait_for(lambda: len(requests) >= 8 and "Reopened" in screen(), "saved session did not continue", 20)
        users = [m["content"] for m in requests[7] if m["role"] == "user"]
        assert users == ["first", "steer", "expanded value", "stop", "queued\n\ncurrent", "inspect", "another\n\nafter\n\ncurrent", "reopen"], users
        send("before headers")
        key("Enter")
        wait_for(lambda: len(requests) >= 9, "pre-header request did not start", 15)
        key("Escape")
        wait_for(lambda: "Request cancelled." in screen(), "escape did not interrupt the request before headers", 8)
        assert not headers_finish.is_set()
        send("failure")
        key("Enter")
        wait_for(lambda: len(requests) >= 10 and "Failing" in screen(), "failure request did not start", 15)
        send("save")
        key("Enter")
        wait_for(lambda: "Steering: save" in screen(), "failure steering was not queued", 8)
        send("follow")
        key("M-Enter")
        wait_for(lambda: "Follow-up: follow" in screen(), "failure follow-up was not queued", 8)
        failure_finish.set()
        wait_for(lambda: "Response incomplete" in screen() and "Steering: save" not in screen() and "Follow-up: follow" not in screen() and "save" in screen() and "follow" in screen(), "failure did not restore queued messages", 10)
        assert len(requests) == 10, requests
        key("Enter")
        wait_for(lambda: len(requests) >= 11 and "Recovered" in screen(), "restored messages were not sent after failure", 15)
        assert [m["content"] for m in requests[10] if m["role"] == "user"][-1] == "save\n\nfollow", requests[10]
        send("run shell")
        key("Enter")
        marker = pathlib.Path(directory) / "shell.state"
        wait_for(lambda: len(requests) >= 12 and marker.exists() and pidfile.exists() and "[tool] bash: started" in screen(), "shell tool did not start", 20)
        send("after shell")
        key("Enter")
        wait_for(lambda: "Steering: after shell" in screen(), "shell steering was not queued", 8)
        key("Escape")
        wait_for(lambda: "Steering: after shell" not in screen() and "after shell" in screen() and "[tool] bash: error" in screen(), "escape did not interrupt the shell and restore steering", 10)
        assert marker.read_text() == "running"
        shell_pid = int(pidfile.read_text())

        def shell_stopped():
            try:
                os.kill(shell_pid, 0)
                return False
            except ProcessLookupError:
                return True

        wait_for(shell_stopped, "cancelled shell was not reaped", 8)
        shell_reaped = True
        key("Enter")
        wait_for(lambda: len(requests) >= 13 and "After shell" in screen(), "shell steering did not resume", 15)
        assert [m["content"] for m in requests[12] if m["role"] == "user"][-1] == "after shell", requests[12]
        send("old work")
        key("Enter")
        wait_for(lambda: len(requests) >= 14 and "Before new" in screen(), "new-session request did not start", 15)
        send("carry")
        key("Enter")
        wait_for(lambda: "Steering: carry" in screen(), "new-session steering was not queued", 8)
        send("/new")
        key("Enter")
        wait_for(lambda: "New session started." in screen() and "> carry" in screen(), "new session did not restore queued input", 10)
        assert not new_finish.is_set()
        key("Enter")
        wait_for(lambda: len(requests) >= 15 and "New session" in screen(), "new session did not send the restored input", 15)
        assert [m["content"] for m in requests[14] if m["role"] == "user"] == ["carry"], requests[14]
        assert len(list(pathlib.Path(directory).glob("*.sqlite"))) == 2
        send("fork slow")
        key("Enter")
        wait_for(lambda: len(requests) >= 16 and "Before fork" in screen(), "fork request did not start", 15)
        send("queued fork")
        key("Enter")
        wait_for(lambda: "Steering: queued fork" in screen(), "fork steering was not queued", 8)
        send("/fork")
        key("Enter")
        wait_for(lambda: "Choose a message" in screen(), "fork selector did not open", 10)
        key("1", "Enter")
        wait_for(lambda: "Forked to new session." in screen() and "> carry" in screen() and "queued fork" in screen(), "fork did not restore selected and queued text", 10)
        assert len(requests) == 16 and not fork_finish.is_set()
        key("Enter")
        wait_for(lambda: len(requests) >= 17 and "Fork response" in screen(), "fork draft was not sent", 15)
        assert [m["content"] for m in requests[16] if m["role"] == "user"] == ["carry\n\nqueued fork"], requests[16]
        assert len(list(pathlib.Path(directory).glob("*.sqlite"))) == 3
        send("/exit")
        key("Enter")
        wait_for(lambda: run("display-message", "-p", "-t", "live", "#{pane_dead}").stdout.strip() == "1", "resumed terminal failed to exit", 15)
        print("live terminal streaming, naming, session changes, queues, cancellation, and SQLite resume passed")
    finally:
        if pidfile.exists() and not shell_reaped:
            try:
                pid = int(pidfile.read_text())
                if os.getpgid(pid) == pid:
                    os.killpg(pid, signal.SIGKILL)
            except (ProcessLookupError, ValueError):
                pass
        more.set()
        finish.set()
        stop_finish.set()
        recover_finish.set()
        headers_finish.set()
        failure_finish.set()
        new_finish.set()
        fork_finish.set()
        run("kill-server", check=False)
        server.shutdown()
        server.server_close()
