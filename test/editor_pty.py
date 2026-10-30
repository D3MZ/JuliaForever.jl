import json
import os
import pathlib
import pty
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time
import fcntl

root, reference = (pathlib.Path(value).resolve() for value in sys.argv[1:3])
oracle = json.loads(reference.read_text())

with tempfile.TemporaryDirectory(prefix="jf-editor-") as temporary:
    workspace = pathlib.Path(temporary)
    prompts = workspace / ".pi" / "prompts"
    prompts.mkdir(parents=True)
    (prompts / "jf-editor-template.md").write_text("hello $1")
    requests = workspace / "requests.jsonl"
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 36, 0, 0))
    original = termios.tcgetattr(slave)
    env = os.environ.copy()
    env.update(JF_SESSION_REQUESTS=str(requests), JF_SESSION_DIR=str(workspace / "sessions"), JF_PROVIDER="openai", OPENAI_MODEL="fixture", OPENAI_API_KEY="editor-test", TERM="xterm", PI_CODING_AGENT_DIR=str(workspace / "agent"))
    env.pop("JF_INSTRUCTIONS_DIR", None)
    env.pop("JF_SESSION_FAIL", None)
    command = [sys.argv[3], "--startup-file=no", "--compiled-modules=existing", f"--project={root}", str(root / "test/session_cli_process.jl"), "--no-session"]
    process = subprocess.Popen(command, cwd=workspace, env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
    output = bytearray()

    def wait_for(predicate, seconds=45):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if predicate():
                return
            readable, _, _ = select.select([master], [], [], 0.1)
            if readable:
                try:
                    output.extend(os.read(master, 65536))
                except OSError:
                    break
            if process.poll() is not None:
                if predicate():
                    return
                break
        raise AssertionError(f"terminal did not reach expected state; output={bytes(output)!r}")

    def messages():
        if not requests.exists():
            return []
        try:
            return [json.loads(line) for line in requests.read_text().splitlines()]
        except json.JSONDecodeError:
            return []

    try:
        wait_for(lambda: b"> " in output)
        for index, (keys, expected) in enumerate(zip(oracle["inputs"], oracle["submitted"])):
            start = len(output)
            os.write(master, "".join(keys).encode())
            wait_for(lambda: len(messages()) > index)
            actual = messages()[index][-1]["content"]
            assert actual == expected, (index, expected, actual, bytes(output))
            wait_for(lambda: b"reply:" in output[start:])

        start = len(output)
        os.write(master, b"\r  \rdiscard me\x03kept\r")
        wait_for(lambda: len(messages()) > len(oracle["inputs"]))
        assert messages()[-1][-1]["content"] == "kept"
        wait_for(lambda: b"reply:kept" in output[start:])
        count = len(messages())
        start = len(output)
        os.write(master, b"/jf-editor-template z\r")
        wait_for(lambda: len(messages()) > count)
        assert messages()[-1][-1]["content"] == "hello z"
        wait_for(lambda: b"reply:hello z" in output[start:])
        os.write(master, b"\x03\x03")
        wait_for(lambda: process.poll() is not None)
        assert process.returncode == 0, bytes(output)
        assert termios.tcgetattr(slave) == original, "terminal settings were not restored"
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
        os.close(slave)

    master, slave = pty.openpty()
    original = termios.tcgetattr(slave)
    process = subprocess.Popen(command, cwd=workspace, env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
    output = bytearray()
    try:
        wait_for(lambda: b"> " in output)
        count = len(messages())
        start = len(output)
        os.write(master, b"ab\x1b[D\x04\r")
        wait_for(lambda: len(messages()) > count)
        assert messages()[-1][-1]["content"] == "a"
        wait_for(lambda: b"reply:a" in output[start:])
        os.write(master, b"\x04")
        wait_for(lambda: process.poll() is not None)
        assert process.returncode == 0, bytes(output)
        assert termios.tcgetattr(slave) == original, "terminal settings were not restored"
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
        os.close(slave)

    requests = workspace / "session-requests.jsonl"
    env["JF_SESSION_REQUESTS"] = str(requests)
    subprocess.run(command[:-1] + ["first"], cwd=workspace, env=env, check=True, capture_output=True, timeout=90)
    first = next((workspace / "sessions").glob("*.sqlite"))
    subprocess.run(command[:-1] + ["second"], cwd=workspace, env=env, check=True, capture_output=True, timeout=90)
    master, slave = pty.openpty()
    original = termios.tcgetattr(slave)
    process = subprocess.Popen(command[:-1] + ["--session", str(first)], cwd=workspace, env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
    output = bytearray()
    try:
        wait_for(lambda: b"> " in output)
        os.write(master, b"/resume\r")
        wait_for(lambda: b"Choose a session" in output)
        os.write(master, b"1\r")
        wait_for(lambda: b"Resuming session." in output and output.count(b"\x1b[?2004h") >= 2)
        count = len(messages())
        start = len(output)
        os.write(master, b"continued\r")
        wait_for(lambda: len(messages()) > count)
        context = [message["content"] for message in messages()[-1] if message["role"] in ("user", "assistant")]
        assert context == ["second", "reply:second", "continued"], context
        wait_for(lambda: b"reply:continued" in output[start:])
        os.write(master, b"/tree\r")
        wait_for(lambda: b"Choose a message" in output)
        os.write(master, b"3\r")
        wait_for(lambda: b"Message [" in output)
        count = len(messages())
        start = len(output)
        os.write(master, b"alternate\r")
        wait_for(lambda: len(messages()) > count)
        context = [message["content"] for message in messages()[-1] if message["role"] in ("user", "assistant")]
        assert context == ["second", "reply:second", "alternate"], context
        wait_for(lambda: b"reply:alternate" in output[start:])
        wait_for(lambda: output.count(b"\x1b[?2004h") >= 3)
        os.write(master, b"/exit\r")
        wait_for(lambda: process.poll() is not None)
        assert process.returncode == 0, bytes(output)
        assert termios.tcgetattr(slave) == original, "terminal settings were not restored"
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
        os.close(slave)

    master, slave = pty.openpty()
    original = termios.tcgetattr(slave)
    process = subprocess.Popen(command, cwd=workspace, env=env, stdin=slave, stdout=subprocess.PIPE, stderr=slave, start_new_session=True)
    output = bytearray()
    redirected = bytearray()

    def reply_redirected():
        readable, _, _ = select.select([process.stdout], [], [], 0)
        if readable:
            redirected.extend(os.read(process.stdout.fileno(), 65536))
        return b"reply:redirected\n" in redirected

    try:
        wait_for(lambda: b"> " in output)
        os.write(master, b"redirected\r")
        wait_for(reply_redirected)
        os.write(master, b"/exit\r")
        wait_for(lambda: process.poll() is not None)
        assert process.returncode == 0, bytes(output)
        assert redirected == b"reply:redirected\n", bytes(redirected)
        assert termios.tcgetattr(slave) == original, "terminal settings were not restored"
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
        os.close(slave)

    print(f"PTY editor and Pi differential: {len(oracle['inputs']) + 8} passed")
