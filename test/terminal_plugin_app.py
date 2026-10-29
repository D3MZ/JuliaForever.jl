import os
import json
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path


app = Path(sys.argv[1]).resolve()
project = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="jf-plugin-app-") as temporary:
    directory = Path(temporary)
    provider = directory / "provider.jl"
    shutil.copyfile(project / "test/terminal_provider.jl", provider)
    events = directory / "events"
    environment = directory / "environment"
    environment.mkdir()
    (environment / "Project.toml").write_text('[deps]\nGreetingPlugin = "ae76cdcb-7d2c-4eba-93ad-b5f8b9e38b49"\n')
    package = tomllib.loads((project / "Project.toml").read_text())
    manifest = (project / "Manifest.toml").read_text()
    manifest = re.sub(r"(?ms)^\[\[deps\.JuliaForever\]\]\n.*?(?=^\[\[deps\.|\Z)", "", manifest)
    manifest += f'\n[[deps.JuliaForever]]\ndeps = {json.dumps(sorted(package["deps"]))}\npath = {json.dumps(str(project))}\nuuid = "{package["uuid"]}"\nversion = "{package["version"]}"\n'
    manifest += f'\n[[deps.GreetingPlugin]]\ndeps = ["JuliaForever"]\npath = {json.dumps(str(project / "test/fixtures/GreetingPlugin"))}\nuuid = "ae76cdcb-7d2c-4eba-93ad-b5f8b9e38b49"\nversion = "0.1.0"\n'
    (environment / "Manifest.toml").write_text(manifest)
    env = dict(os.environ, HOME=str(directory), JF_FIXTURE="plugin", JF_PROVIDER="openai", OPENAI_MODEL="fixture", OPENAI_API_KEY="synthetic-secret", JF_TEST_EVENTS=str(events), JF_TEST_PLUGIN="", JF_INSTRUCTIONS_DIR=str(directory))
    selected = ["--plugin-env", str(environment), "--plugin", "GreetingPlugin"]

    def run(*args, **values):
        return subprocess.run([str(app), "-L", str(provider), "--", *args], cwd=directory, env=dict(env, **values), capture_output=True, text=True, timeout=90)

    result = run(*selected, "start")
    assert result.returncode == 0, result.stderr
    assert result.stdout == "Before\nplugin:Hello, Ada!\n", result.stdout
    assert events.read_text().splitlines() == ["agent_start", "tool_execution_end", "agent_end"]
    assert "[tool] greet: ok" in result.stderr, result.stderr
    assert "world prior" not in result.stderr, result.stderr

    failure = run(*selected, "start", JF_TEST_PLUGIN="factory")
    assert failure.returncode == 2, failure.stderr
    assert "factory failure: [redacted]" in failure.stderr, failure.stderr
    assert "synthetic-secret" not in failure.stderr, failure.stderr

print("installed native plugin activation and failure diagnostics passed")
