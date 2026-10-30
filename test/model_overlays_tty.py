import json
import os
import pty
import subprocess
import sys

julia, project, workspace, *args = sys.argv[1:]
master, slave = pty.openpty()
try:
    process = subprocess.Popen(
        [julia, "--startup-file=no", "--compiled-modules=existing", "--compile=min", "-O0", f"--project={project}", "-m", "JuliaForever", *args],
        cwd=workspace,
        stdin=slave,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    os.close(slave)
    os.write(master, b"n\n/exit\n")
    try:
        output, diagnostics = process.communicate(timeout=90)
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate()
        raise
    print(json.dumps({"status": process.returncode, "output": output.decode(), "diagnostics": diagnostics.decode()}))
finally:
    os.close(master)
