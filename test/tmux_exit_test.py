import os
import pathlib
import shlex
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from tmux_exit import wait_for_exit


class TerminalExitTest(unittest.TestCase):
    def test_nudges_again_when_child_exits_after_first_signal(self):
        signals = 0

        def run(*args):
            if args[-1] == "#{pid}":
                return SimpleNamespace(stdout="123\n")
            return SimpleNamespace(stdout="1|0|\n" if signals >= 2 else "1||\n")

        def nudge(pid, sig):
            nonlocal signals
            self.assertEqual((pid, sig), (123, signal.SIGCHLD))
            signals += 1

        with patch("os.kill", side_effect=nudge):
            self.assertEqual(wait_for_exit(run, "probe", seconds=.8), ("0", ""))

    def test_missed_sigchld_still_reports_failure(self):
        signalled = False

        def run(*args):
            if args[-1] == "#{pid}":
                return SimpleNamespace(stdout="123\n")
            return SimpleNamespace(stdout="1|7|\n" if signalled else "1||\n")

        def nudge(pid, sig):
            nonlocal signalled
            self.assertEqual((pid, sig), (123, signal.SIGCHLD))
            signalled = True

        with patch("os.kill", side_effect=nudge):
            self.assertEqual(wait_for_exit(run, "probe", seconds=.2), ("7", ""))

    def check_exit(self, outcome):
        socket = f"jf-exit-test-{os.getpid()}-{outcome}"
        tmux = ["tmux", "-f", "/dev/null", "-L", socket]

        def run(*args):
            return subprocess.run([*tmux, *args], check=True, text=True, capture_output=True)

        with tempfile.TemporaryDirectory(prefix="jf-exit-test-") as directory:
            ready = pathlib.Path(directory) / "ready"
            release = pathlib.Path(directory) / "release"
            code = f"""
import os, pathlib, signal, time
signal.signal(signal.SIGHUP, signal.SIG_IGN)
time.sleep(.5)
for fd in (0, 1, 2):
    os.close(fd)
pathlib.Path({str(ready)!r}).touch()
deadline = time.monotonic() + 15
while not pathlib.Path({str(release)!r}).exists() and time.monotonic() < deadline:
    time.sleep(.02)
if {outcome!r} == 'signal':
    os.kill(os.getpid(), signal.SIGTERM)
os._exit(int({outcome!r}))
"""
            try:
                run("new-session", "-d", "-s", "probe", shlex.join([sys.executable, "-c", code]))
                run("set-option", "-g", "remain-on-exit", "on")
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    state = run("display-message", "-p", "-t", "probe", "#{pane_dead}|#{pane_dead_status}|#{pane_dead_signal}").stdout.strip()
                    if ready.exists() and state == "1||":
                        break
                    time.sleep(.05)
                else:
                    self.fail(f"terminal did not close before process exit: {state!r}")
                with self.assertRaisesRegex(AssertionError, "exit status unavailable"):
                    wait_for_exit(run, "probe", seconds=.2)
                release.touch()
                status, death_signal = wait_for_exit(run, "probe", seconds=10)
                if outcome == "signal":
                    self.assertEqual(status, "")
                    self.assertTrue(death_signal)
                else:
                    self.assertEqual((status, death_signal), (outcome, ""))
            finally:
                subprocess.run([*tmux, "kill-server"], capture_output=True)

    def test_success_after_terminal_closes(self):
        self.check_exit("0")

    def test_failure_after_terminal_closes(self):
        self.check_exit("7")

    def test_signal_after_terminal_closes(self):
        self.check_exit("signal")


if __name__ == "__main__":
    unittest.main()
