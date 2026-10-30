import fcntl
import os
import pty
import select
import struct
import subprocess
import sys
import termios
import time

julia, project, root = sys.argv[1:]
for mode in ("fullscreen", "regular"):
    env = os.environ.copy()
    for name in ("OPENAI_API_KEY", "OPENAI_MODEL", "JF_PROVIDER"):
        env.pop(name, None)
    env.update(HOME=root, JF_CHATGPT_DIR=root + "/chatgpt", PI_CODING_AGENT_DIR=root + "/pi", JF_INSTRUCTIONS_DIR=root, JF_SESSION_DIR=root + "/sessions", TERM="xterm-256color")
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    cmd = [julia, "--startup-file=no", "--compiled-modules=existing", "--project=" + project, "-m", "JuliaForever", "--tui-mode", mode, "--model", "fixture-model", "--no-session"]
    process = subprocess.Popen(cmd, cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
    os.close(slave)
    output = bytearray()
    def waitfor(predicate, timeout=90):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], .2)
            if ready:
                try:
                    output.extend(os.read(master, 65536))
                except OSError:
                    pass
            if predicate():
                return
            if process.poll() is not None:
                raise RuntimeError("process exited early: " + output.decode(errors="replace")[-1500:])
        raise RuntimeError("terminal timed out: " + output.decode(errors="replace")[-1500:])
    try:
        waitfor(lambda: b"fixture-model" in output and (b"ready" in output if mode == "fullscreen" else b"Julia Forever" in output and b"> " in output))
        assert (b"\x1b[?1049h" in output) == (mode == "fullscreen")
        os.write(master, b"/exit\r")
        waitfor(lambda: process.poll() is not None, 20)
        assert process.returncode == 0
        assert b"fixture-access" not in output
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
print("ChatGPT terminal modes passed")
