import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from terminal_pty import Session

julia, project = sys.argv[1], Path(sys.argv[2])
oracle = json.loads(subprocess.check_output(["node", str(project / "test/fullscreen_pi.mjs")]))
with tempfile.TemporaryDirectory(prefix="jf-fullscreen-pty-") as directory:
    session = Session(julia, project, directory, args=("--tui-mode", "fullscreen"))
    try:
        session.until(lambda: b"> " in session.output, "initial prompt", timeout=90)
        os.write(session.master, b"/exit\r")
        session.wait_exit()
        while True:
            before = len(session.output)
            session.read()
            if len(session.output) == before:
                break
        actual = {"enter": b"\x1b[?1049h" in session.output, "exit": b"\x1b[?1049l" in session.output}
        assert session.process.returncode == 0, session.output
        assert actual == oracle, (actual, oracle, session.output)
    finally:
        session.close()
with tempfile.TemporaryDirectory(prefix="jf-fullscreen-redirect-") as directory:
    session = Session(julia, project, directory, stdout_tty=False, args=("--tui-mode", "fullscreen"))
    try:
        session.ready()
        os.write(session.master, b"redirected\r")
        session.until(lambda: session.stdout.exists() and "reply:redirected" in session.stdout.read_text(), "redirected output")
        os.write(session.master, b"/exit\r")
        session.wait_exit()
        assert session.process.returncode == 0, session.output
        assert b"\x1b[?1049h" not in session.output, session.output
    finally:
        session.close()
print("fullscreen Pi differential passed")
