import os
import pathlib
import pty
import select
import subprocess
import sys
import tempfile
import time

project = pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory() as directory:
    env = os.environ.copy()
    for key in ("JF_PROVIDER", "OPENAI_API_KEY", "OPENAI_MODEL", "OPENAI_BASE_URL"):
        env.pop(key, None)
    env.update(HOME=directory, JF_CHATGPT_DIR=directory + "/chatgpt", PI_CODING_AGENT_DIR=directory + "/pi")
    master, slave = pty.openpty()
    process = subprocess.Popen([sys.argv[1], "--startup-file=no", "--compiled-modules=existing", "--project=" + str(project), "-m", "JuliaForever"], stdin=slave, stdout=slave, stderr=slave, env=env, start_new_session=True)
    os.close(slave)
    output = bytearray()
    deadline = time.monotonic() + 90
    try:
        while b"Continue with ChatGPT?" not in output and time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], 1)
            if ready:
                try:
                    output.extend(os.read(master, 65536))
                except OSError:
                    break
            if process.poll() is not None:
                break
        assert b"Continue with ChatGPT?" in output, output.decode(errors="replace")
        os.write(master, b"n\n")
        assert process.wait(timeout=10) == 0
        assert not list(pathlib.Path(directory + "/chatgpt").glob("*.json"))
        print("ChatGPT terminal startup and cancellation passed")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
