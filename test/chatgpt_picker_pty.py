import fcntl
import os
import pathlib
import pty
import select
import struct
import subprocess
import sys
import termios
import time

julia, project, root = sys.argv[1:]
env = os.environ.copy()
env.update(HOME=root, PI_CODING_AGENT_DIR=root + "/pi", JF_INSTRUCTIONS_DIR=root, TERM="xterm-256color")
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
script = pathlib.Path(project) / "test" / "chatgpt_picker_process.jl"
process = subprocess.Popen([julia, "--startup-file=no", "--compiled-modules=existing", "--project=" + project, str(script), root], cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
os.close(slave)
output = bytearray()

def waitfor(predicate, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if select.select([master], [], [], .2)[0]:
            try:
                output.extend(os.read(master, 65536))
            except OSError:
                pass
        if predicate():
            return
        if process.poll() is not None:
            if predicate():
                return
            raise RuntimeError("picker exited early: " + output.decode(errors="replace")[-1200:])
    raise RuntimeError("picker timed out: " + output.decode(errors="replace")[-1200:])

try:
    waitfor(lambda: b"\x1b[?1049h" in output and b"ready" in output)
    os.write(master, b"/model\r")
    waitfor(lambda: b"First Friendly" in output and b"Second Friendly" in output)
    os.write(master, b"\x1b[B\x1b[B\x1b[B\r")
    waitfor(lambda: b"second-model |" in output)
    waitfor(lambda: not termios.tcgetattr(master)[3] & termios.ICANON, 20)
    os.write(master, b"/exit\r")
    waitfor(lambda: process.poll() is not None, 20)
    assert process.returncode == 0
    assert b"fixture-access" not in output
    print("ChatGPT model picker passed")
finally:
    if process.poll() is None:
        process.kill()
        process.wait()
    os.close(master)
