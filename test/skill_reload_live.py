import fcntl
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

root = pathlib.Path(sys.argv[1]).resolve()
julia = sys.argv[2]
mode = sys.argv[3]

with tempfile.TemporaryDirectory(prefix="jf-skill-reload-live-") as directory:
    workspace = pathlib.Path(directory).resolve()
    path = workspace / ".pi" / "skills" / "example" / "SKILL.md"
    path.parent.mkdir(parents=True)
    def skill(description):
        path.write_text(f"---\nname: example\ndescription: {description}\n---\nprivate body\n")
    skill("old metadata")
    requests = workspace / "requests.jsonl"
    gate = workspace / "gate"
    env = os.environ.copy()
    env.update(HOME=directory, JF_PROVIDER="openai", OPENAI_MODEL="fixture", OPENAI_API_KEY="synthetic", JF_SESSION_DIR=str(workspace / "sessions"), PI_CODING_AGENT_DIR=str(workspace / "agent"), JF_RELOAD_REQUESTS=str(requests), JF_RELOAD_GATE=str(gate), TERM="xterm")
    env.pop("JF_INSTRUCTIONS_DIR", None)
    command = [julia, "--startup-file=no", "--compiled-modules=existing", f"--project={root}", str(root / "test/skill_reload_live_process.jl"), "--tui-mode", mode]
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
    original = termios.tcgetattr(slave)
    process = subprocess.Popen(command, cwd=workspace, env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
    output = bytearray()

    def messages():
        if not requests.exists():
            return []
        try:
            return [json.loads(line) for line in requests.read_text().splitlines()]
        except json.JSONDecodeError:
            return []

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
        raise AssertionError(f"terminal did not reach expected state; output={bytes(output)!r}; requests={messages()!r}")

    def system(request):
        return "\n".join(message["content"] for message in request if message["role"] == "system")

    def expanded(args):
        return f'<skill name="example" location="{path}">\nReferences are relative to {path.parent}.\n\nprivate body\n</skill>\n\n{args}'

    def settled(token):
        frame = output.rsplit(b"\x1b[H\x1b[2J", 1)[-1]
        return frame.count(token) >= 2 and b"fixture | ready" in frame

    def reload_when_idle(token):
        if mode == "fullscreen":
            wait_for(lambda: settled(token))
            start = len(output)
            os.write(master, b"/reload\r")
            wait_for(lambda: b"Reloaded skills." in output[start:])
            wait_for(lambda: not termios.tcgetattr(slave)[3] & termios.ICANON)
            return
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            start = len(output)
            os.write(master, b"/reload\r")
            wait_for(lambda: b"Reloaded skills." in output[start:] or b"Wait for the current response to finish before reloading." in output[start:])
            if b"Reloaded skills." in output[start:]:
                wait_for(lambda: b"\x1b[?2004h" in output[start:])
                return
            time.sleep(0.05)
        raise AssertionError(f"reload remained busy after the queued response: {bytes(output)!r}")

    try:
        wait_for(lambda: b"> " in output)
        os.write(master, b"first\r")
        wait_for(lambda: len(messages()) == 1 and b"reply:first" in output)
        skill("new metadata")
        os.write(master, b"queued\r")
        wait_for(lambda: b"Steering: queued" in output)
        os.write(master, b"/skill:example queued-skill\r")
        wait_for(lambda: b"Steering: <skill name=" in output)
        os.write(master, b"/reload\r")
        wait_for(lambda: b"Wait for the current response to finish before reloading." in output)
        assert len(messages()) == 1 and not gate.exists()
        gate.touch()
        wait_for(lambda: len(messages()) == 2 and b"reply:queued" in output)
        assert "old metadata" in system(messages()[0]) and "old metadata" in system(messages()[1])
        assert [m["content"] for m in messages()[1] if m["role"] == "user"] == ["first", "queued"]
        wait_for(lambda: len(messages()) == 3)
        assert [m["content"] for m in messages()[2] if m["role"] == "user"] == ["first", "queued", expanded("queued-skill")]
        reload_when_idle(b"queued-skill")
        os.write(master, b"/skill:example after\r")
        wait_for(lambda: len(messages()) == 4)
        assert "new metadata" in system(messages()[3]) and "old metadata" not in system(messages()[3])
        assert [m["content"] for m in messages()[3] if m["role"] == "user"] == ["first", "queued", expanded("queued-skill"), expanded("after")]
        if mode == "fullscreen":
            wait_for(lambda: settled(b"after"))
        else:
            reload_when_idle(b"after")
        os.write(master, b"/exit\r")
        wait_for(lambda: process.poll() is not None)
        assert process.returncode == 0, bytes(output)
        assert termios.tcgetattr(slave) == original
        resumed = subprocess.run([*command, "--continue", "resumed"], cwd=directory, env=env, capture_output=True, text=True, timeout=60)
        assert resumed.returncode == 0, (resumed.stdout, resumed.stderr)
        assert len(messages()) == 5 and "new metadata" in system(messages()[4]) and "old metadata" not in system(messages()[4])
        assert [m["content"] for m in messages()[4] if m["role"] == "user"] == ["first", "queued", expanded("queued-skill"), expanded("after"), "resumed"]
        print(f"{mode} skill reload and SQLite resume passed")
    finally:
        gate.touch()
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
        os.close(slave)
