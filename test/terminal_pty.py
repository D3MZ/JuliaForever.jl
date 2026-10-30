import fcntl
import json
import os
import pty
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time
from pathlib import Path


class Session:
    def __init__(self, julia, project, directory, *, stdout_tty=True, stderr_tty=True, term="xterm-256color", args=(), mode="echo", plugin=""):
        self.directory = Path(directory)
        self.capture = self.directory / "capture.jsonl"
        self.stdout = self.directory / "stdout"
        self.stderr = self.directory / "stderr"
        self.master, self.slave = pty.openpty()
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        self.initial_mode = termios.tcgetattr(self.slave)
        self.output = b""
        self.files = []
        env = dict(os.environ, HOME=str(self.directory), TERM=term, JF_INSTRUCTIONS_DIR=str(self.directory), JF_FIXTURE=mode, JF_CAPTURE=str(self.capture), JF_PROVIDER="openai", OPENAI_MODEL="fixture", OPENAI_API_KEY="fixture-key", JF_TEST_EVENTS=str(self.directory / "plugin-events"), JF_TEST_PLUGIN=plugin)
        def destination(enabled, path):
            if enabled:
                return self.slave
            f = open(path, "wb")
            self.files.append(f)
            return f
        self.process = subprocess.Popen([julia, "--startup-file=no", "--project=" + str(project), str(project / "test/terminal_process.jl"), *args], cwd=self.directory, stdin=self.slave, stdout=destination(stdout_tty, self.stdout), stderr=destination(stderr_tty, self.stderr), env=env, close_fds=True)

    def read(self):
        ready, _, _ = select.select([self.master], [], [], 0.1)
        if ready:
            self.output += os.read(self.master, 65536)

    def until(self, predicate, label, timeout=30):
        deadline = time.monotonic() + timeout
        while not predicate():
            if self.process.poll() is not None:
                raise AssertionError(f"process exited {self.process.returncode} while waiting for {label}: {self.output!r}")
            if time.monotonic() > deadline:
                raise AssertionError(f"timed out waiting for {label}: {self.output!r}")
            self.read()

    def records(self):
        if not self.capture.exists():
            return []
        return [json.loads(line) for line in self.capture.read_bytes().split(b"\n")[:-1]]

    def ready(self):
        self.until(lambda: b"> " in self.output, "initial prompt")

    def send(self, text, expected):
        offset, count = len(self.output), len(self.records())
        os.write(self.master, text)
        self.until(lambda: len(self.records()) > count, "provider input")
        assert self.records()[count] == expected, (self.records()[count], expected, self.output)
        self.until(lambda: b"reply:" in self.output[offset:] and b"> " in self.output[offset:].split(b"reply:", 1)[1], "next prompt")

    def wait_exit(self):
        self.until(lambda: self.process.poll() is not None, "process exit", timeout=30)

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait()
        for f in self.files:
            f.close()
        os.close(self.master)
        os.close(self.slave)


def editor(julia, project, directory):
    session = Session(julia, project, directory)
    try:
        session.ready()
        session.send("αβ!".encode() + b"\x1b[D\x7fX\r", "αX!")
        session.send(b"alpha\nbeta\x1b[A\x01X\x1b[B\x05!\r", "Xalpha\nbeta!")
        session.send(b"\x1b[13;2uone\r", "\none")
        session.send(b"\x1b[27;2;13~two\r", "\ntwo")
        session.send(b"\x1b[200~   one\r\n\t  two\rthree\x1b[201~\r", "   one\n\t  two\nthree")
        session.send(b"single\r", "single")
        session.send(b"draft\x1b[A\x1b[B\r", "draft")
        session.send(b"\x1b[A!\r", "draft!")
        session.send(b"\x1b<\x1b[F+\r", "αX!+")
        session.send(b"ready\x1b\r\r", "ready")
        assert b"Alt+Enter follow-up is not supported." in session.output
        session.send(b"ready\x07\r", "ready")
        assert b"External editor is not supported." in session.output
        session.send(b"discard\x03kept\r", "kept")
        session.send(b"ab\x1b[D\x04\r", "a")
        os.write(session.master, b"\x04")
        session.wait_exit()
        assert session.process.returncode == 0, (session.process.returncode, session.output)
        assert b"Error in the keymap" not in session.output
        restored = termios.tcgetattr(session.slave)
        assert restored == session.initial_mode, (session.initial_mode, restored)
    finally:
        session.close()


def tree_editor(julia, project, directory):
    fixture = str(project / "test" / "fixtures")
    session = Session(julia, project, directory, args=("--plugin-env", fixture, "--plugin", "GreetingPlugin"))
    try:
        session.ready()
        session.send(b"first\r", "first")
        offset = len(session.output)
        os.write(session.master, b"/tree\r")
        session.until(lambda: b"Choose a message" in session.output[offset:], "tree selector")
        os.write(session.master, b"1\n")
        session.until(lambda: b"Message [first]" in session.output[offset:], "tree edit prompt")
        os.write(session.master, b"changed\n")
        session.until(lambda: session.records() == ["first", "changed"], "tree branch request")
        session.until(lambda: b"reply:changed" in session.output[offset:] and b"> " in session.output[offset:].split(b"reply:changed", 1)[1], "prompt after branch")
        os.write(session.master, b"\x04")
        session.wait_exit()
        assert session.process.returncode == 0, (session.process.returncode, session.output)
        assert (directory / "plugin-events").read_text().splitlines() == ["agent_start", "agent_end", "agent_start", "agent_end"]
        assert termios.tcgetattr(session.slave) == session.initial_mode
    finally:
        session.close()


def redirected(julia, project, directory):
    session = Session(julia, project, directory, stdout_tty=False)
    try:
        session.ready()
        os.write(session.master, b"redirected\r")
        session.until(lambda: session.records() == ["redirected"], "redirected provider input")
        session.until(lambda: session.stdout.exists() and "reply:redirected" in session.stdout.read_text(), "redirected output")
        session.until(lambda: session.output.count(b"\x1b[?2004h") >= 2, "next editor")
        os.write(session.master, b"/exit\r")
        session.wait_exit()
        assert session.process.returncode == 0
    finally:
        session.close()


def no_terminal_output(julia, project, directory):
    session = Session(julia, project, directory, stdout_tty=False, stderr_tty=False)
    try:
        session.until(lambda: session.stderr.exists() and "> " in session.stderr.read_text(), "line prompt")
        os.write(session.master, b"first\rsecond\r/exit\r")
        session.wait_exit()
        assert session.process.returncode == 0
        assert session.records() == ["first", "second"], session.records()
        assert session.stdout.read_text() == "reply:first\nreply:second\n"
        assert b"\x1b[?2004h" not in session.stderr.read_bytes()
    finally:
        session.close()


def dumb_terminal(julia, project, directory):
    session = Session(julia, project, directory, term="dumb")
    try:
        session.ready()
        os.write(session.master, b"first\r/exit\r")
        session.wait_exit()
        assert session.process.returncode == 0
        assert session.records() == ["first"], session.records()
        assert b"\x1b[?2004h" not in session.output
    finally:
        session.close()


def plugin_terminal(julia, project, directory):
    args = ("--plugin-env", str(project / "test/fixtures"), "--plugin", "GreetingPlugin")
    session = Session(julia, project, directory, args=args, mode="plugin", plugin="hook")
    try:
        session.ready()
        for prompt in ("one", "two"):
            offset = len(session.output)
            os.write(session.master, prompt.encode() + b"\r")
            session.until(lambda: b"plugin:Hello, Ada!" in session.output[offset:] and b"> " in session.output[offset:].split(b"plugin:Hello, Ada!", 1)[1], "plugin reply and prompt")
        events = (directory / "plugin-events").read_text().splitlines()
        assert events == ["agent_start", "tool_execution_end", "agent_end"] * 2, events
        assert session.output.count(b"hook failure: synthetic-secret") == 2, session.output
        os.write(session.master, b"/exit\r")
        session.wait_exit()
        assert session.process.returncode == 0, session.output
    finally:
        session.close()


def main():
    julia, project = sys.argv[1], Path(sys.argv[2])
    with tempfile.TemporaryDirectory(prefix="jf-terminal-pty-") as root:
        for name, scenario in (("editor", editor), ("tree-editor", tree_editor), ("redirected", redirected), ("no-terminal-output", no_terminal_output), ("dumb-terminal", dumb_terminal), ("plugin", plugin_terminal)):
            directory = Path(root) / name
            directory.mkdir()
            scenario(julia, project, directory)
    print("terminal PTY scenarios passed")


if __name__ == "__main__":
    main()
