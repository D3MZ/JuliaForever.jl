import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time
from tmux_exit import wait_for_exit

project, julia = Path(sys.argv[1]).resolve(), sys.argv[2]
tmux = ['tmux', '-f', '/dev/null', '-L', f'jf-manual-compact-{os.getpid()}']

def run(*args, check=True, env=None):
    return subprocess.run([*tmux, *args], check=check, text=True, capture_output=True, env=env)

def screen():
    return run('capture-pane', '-p', '-J', '-t', 'manual').stdout

def wait(predicate, label, timeout=120):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        text = screen()
        if predicate(text):
            return text
        if run('display-message', '-p', '-t', 'manual', '#{pane_dead}', check=False).stdout.strip() == '1':
            raise AssertionError((label, 'process exited', text))
        time.sleep(.1)
    raise AssertionError((label, screen()))

def send(text):
    run('send-keys', '-t', 'manual', '-l', text)
    run('send-keys', '-t', 'manual', 'Enter')

def calls(path):
    try:
        return [json.loads(line) for line in path.read_text().splitlines()]
    except (FileNotFoundError, json.JSONDecodeError):
        return []

try:
    with tempfile.TemporaryDirectory(prefix='jf-manual-compact-live-') as temporary:
        root = Path(temporary)
        agent = root / 'agent'
        agent.mkdir()
        model = {'id': 'small', 'name': 'Small', 'contextWindow': 1000, 'maxTokens': 64}
        (agent / 'models.json').write_text(json.dumps({'providers': {'fixture': {'api': 'openai-completions', 'apiKey': 'synthetic', 'baseUrl': 'http://localhost', 'models': [model]}}}))
        (agent / 'settings.json').write_text(json.dumps({'compaction': {'enabled': False, 'keepRecentTokens': 5}}))
        history, requests = root / 'history.sqlite', root / 'requests'
        env = dict(os.environ, HOME=str(root), TERM='xterm-256color', PI_CODING_AGENT_DIR=str(agent), JF_INSTRUCTIONS_DIR=str(root), JF_SESSION_DIR=str(root / 'sessions'), JF_COMPACTION_REQUESTS=str(requests), JF_COMPACTION_USAGE='success')
        args = [julia, '--startup-file=no', '--compiled-modules=existing', f'--project={project}', str(project / 'test/compaction_cli_process.jl'), '--history', str(history), '--provider', 'fixture', '--model', 'small']
        initial = subprocess.run(args, cwd=root, env=env, input='first\nsecond\n/exit\n', text=True, capture_output=True, timeout=120)
        assert initial.returncode == 0, (initial.stdout, initial.stderr)
        keys = ('HOME', 'TERM', 'PI_CODING_AGENT_DIR', 'JF_INSTRUCTIONS_DIR', 'JF_SESSION_DIR', 'JF_COMPACTION_REQUESTS', 'JF_COMPACTION_USAGE')
        shell = shlex.join(['env', *[f'{key}={env[key]}' for key in keys], *args, '--tui-mode', 'fullscreen'])
        run('new-session', '-d', '-s', 'manual', '-x', '90', '-y', '30', '-c', str(root), shell, env=env)
        run('set-option', '-t', 'manual', 'remain-on-exit', 'on')
        wait(lambda text: 'small | ready' in text and '> ' in text, 'startup')
        send('/compact  Keep the release date  ')
        wait(lambda text: 'Context compacted.' in text and 'small | ready' in text, 'manual compaction')
        summaries = [call for call in calls(requests) if call['operation'] == 'summarize']
        assert len(summaries) == 1 and 'Additional focus: Keep the release date' in json.dumps(summaries[0]['messages']), summaries
        send('third')
        wait(lambda text: 'reply:third' in text and 'small | ready' in text, 'continued response')
        messages = calls(requests)[-1]['messages']
        contents = [message.get('content') for message in messages]
        assert any('checkpoint' in content for content in contents if isinstance(content, str)), contents
        assert 'second' in contents and 'first' not in contents, contents
        send('/exit')
        status, signal = wait_for_exit(run, 'manual', seconds=30)
        assert status == '0', (status, signal, screen())
    print('interactive manual compaction passed')
finally:
    run('kill-server', check=False)
