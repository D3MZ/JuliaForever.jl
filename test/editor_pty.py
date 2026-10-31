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
    requests = workspace / "requests.jsonl"
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 36, 0, 0))
    env = os.environ.copy()
    env.update(JF_SESSION_REQUESTS=str(requests), JF_SESSION_DIR=str(workspace / "sessions"), JF_PROVIDER="openai", OPENAI_MODEL="fixture", OPENAI_API_KEY="editor-test", TERM="xterm", PI_CODING_AGENT_DIR=str(workspace / "agent"))
    env.pop("JF_INSTRUCTIONS_DIR", None)
    env.pop("JF_SESSION_FAIL", None)
    command = [sys.argv[3], "--startup-file=no", "--compiled-modules=existing", f"--project={root}", str(root / "test/session_cli_process.jl"), "--tui-mode", "regular", "--no-session"]
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

        os.write(master, b"/exit\r")
        wait_for(lambda: process.poll() is not None)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
        os.close(slave)

    print(f"PTY editor and Pi differential: {len(oracle['inputs'])} passed")
