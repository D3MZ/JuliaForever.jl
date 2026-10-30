import json
import os
import subprocess
import tempfile
from pathlib import Path

source = Path(__file__).with_name('headless_auto_compaction.py').read_text().split("with tempfile.TemporaryDirectory(prefix='jf-headless-auto-')")[0]
exec(compile(source, 'headless_auto_compaction.py', 'exec'))

def settings(root, fixture, case):
    env = setup(root, fixture)
    path = root / 'agent/settings.json'
    config = json.loads(path.read_text())
    config['compaction'].update(enabled=False, keepRecentTokens=20000)
    if case == 'override':
        config['compaction']['modelOverrides'] = {'fixture/small': {'keepRecentTokens': 10}}
    path.write_text(json.dumps(config))
    if case in ('focus', 'override', 'ephemeral'):
        project = root / '.pi'
        project.mkdir()
        (project / 'settings.json').write_text(json.dumps({'compaction': {'keepRecentTokens': 5}}))
    return env

def seed(kind, root, fixture, env):
    rpc = RPC(kind, root, fixture, env)
    try:
        for text in ('first', 'second', 'third'):
            rpc.prompt(text)
    finally:
        rpc.close()

def compact(kind, root, fixture, env, case):
    focus = 'Keep the release date' if case == 'focus' else None
    if kind == 'pi':
        rpc = RPC(kind, root, fixture, env, ['--continue'])
        try:
            fields = {'customInstructions': focus} if focus else {}
            result = rpc.ask('manual', 'compact', **fields)
            assert result['success'] == (case != 'small'), (kind, case, result)
        finally:
            rpc.close()
    else:
        line = '/compact  Keep the release date  ' if focus else '/compact'
        result = subprocess.run(command(kind, 'text', root, ['--continue']), cwd=root, env=env, input=line + '\n/exit\n', text=True, capture_output=True, timeout=120)
        assert (result.returncode == 0) == (case != 'small'), (kind, case, result.returncode, result.stdout, result.stderr)
        if case != 'small':
            assert 'Context compacted.' in result.stderr, (kind, case, result.stderr)
    summaries = [request for request in fixture.requests if request['summary']]
    assert len(summaries) == (0 if case == 'small' else 1), (kind, case, summaries)
    if focus:
        assert 'Additional focus: ' + focus in json.dumps(summaries[0]['messages']), (kind, summaries)

def check(kind, root, fixture, env, case):
    rpc = RPC(kind, root, fixture, env, ['--continue'])
    try:
        messages = rpc.ask('messages', 'get_messages')['data']['messages']
        users = [message_text(message) for message in messages if message['role'] == 'user']
        expected = {'focus': ['third'], 'override': ['second', 'third'], 'small': ['first', 'second', 'third']}[case]
        assert users == expected, (kind, case, users)
        summaries = [message for message in messages if message['role'] == 'compactionSummary']
        assert len(summaries) == (0 if case == 'small' else 1), (kind, case, summaries)
        if summaries:
            assert 'checkpoint' in summaries[0]['summary'], (kind, case, summaries)
    finally:
        rpc.close()

def ephemeral(kind, root, fixture, env):
    focus = 'Keep the release date'
    if kind == 'pi':
        rpc = RPC(kind, root, fixture, env, ['--no-session'])
        try:
            for text in ('first', 'second', 'third'):
                rpc.prompt(text)
            assert rpc.ask('manual', 'compact', customInstructions=focus)['success']
            rpc.prompt('fourth')
        finally:
            rpc.close()
    else:
        lines = 'first\nsecond\nthird\n/compact  Keep the release date  \nfourth\n/exit\n'
        result = subprocess.run(command(kind, 'text', root, ['--no-session']), cwd=root, env=env, input=lines, text=True, capture_output=True, timeout=120)
        assert result.returncode == 0 and 'Context compacted.' in result.stderr, (kind, result.returncode, result.stdout, result.stderr)
    summaries = [request for request in fixture.requests if request['summary']]
    assert len(summaries) == 1 and 'Additional focus: ' + focus in json.dumps(summaries[0]['messages']), (kind, summaries)
    final = fixture.requests[-1]['messages']
    assert 'checkpoint' in json.dumps(final) and 'third' in json.dumps(final), (kind, final)

for kind in ('pi', 'julia'):
    if os.environ.get('JF_HEADLESS_KIND', kind) != kind:
        continue
    for case in ('focus', 'override', 'small', 'ephemeral'):
        if os.environ.get('JF_MANUAL_CASE', case) != case:
            continue
        with tempfile.TemporaryDirectory(prefix='jf-terminal-manual-') as temporary:
            root = Path(temporary)
            fixture = Fixture()
            try:
                env = settings(root, fixture, case)
                if case == 'ephemeral':
                    ephemeral(kind, root, fixture, env)
                else:
                    seed(kind, root, fixture, env)
                    compact(kind, root, fixture, env, case)
                    check(kind, root, fixture, env, case)
            finally:
                fixture.close()
print('terminal manual compaction passed')
