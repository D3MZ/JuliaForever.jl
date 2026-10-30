import os
import tempfile
from pathlib import Path

source = Path(__file__).with_name('headless_auto_compaction.py').read_text().split("with tempfile.TemporaryDirectory(prefix='jf-headless-auto-')")[0]
exec(compile(source, 'headless_auto_compaction.py', 'exec'))

def manual(kind, root, fixture, env, failure):
    fixture.fail_summary = failure
    if kind == 'pi':
        rpc = RPC(kind, root, fixture, env, ['--continue'])
        try:
            result = rpc.ask('manual', 'compact')
            assert result['success'] == (not failure), (kind, result)
        finally:
            rpc.close()
    else:
        process = subprocess.run(command(kind, 'text', root, ['--continue']), cwd=root, env=env, input='/compact\n/exit\n', text=True, capture_output=True, timeout=120)
        assert (process.returncode != 0) == failure, (kind, process.returncode, process.stdout, process.stderr)
        if not failure:
            assert 'Context compacted.' in process.stderr, (kind, process.stderr)

def run(kind, root, fixture, env, failure, json_resume):
    path = root / 'agent/settings.json'
    settings = json.loads(path.read_text())
    settings['compaction']['enabled'] = False
    path.write_text(json.dumps(settings))
    for text, args in (('first', []), ('second', ['--continue'])):
        process = subprocess.run(command(kind, 'text', root, [*args, text]), cwd=root, env=env, input='', text=True, capture_output=True, timeout=120)
        assert process.returncode == 0 and 'reply:' + text in process.stdout, (kind, process.stdout, process.stderr)
    manual(kind, root, fixture, env, failure)
    fixture.fail_summary = False
    if json_resume:
        process = subprocess.run(command(kind, 'json', root, ['--continue', 'third']), cwd=root, env=env, input='', text=True, capture_output=True, timeout=120)
        assert process.returncode == 0, (kind, process.stderr)
    rpc = RPC(kind, root, fixture, env, ['--continue'])
    try:
        entries = rpc.ask('entries', 'get_entries')['data']['entries']
        compactions = [entry for entry in entries if entry['type'] == 'compaction']
        messages = rpc.ask('messages', 'get_messages')['data']['messages']
        if failure:
            assert not compactions and not any(message['role'] == 'compactionSummary' for message in messages), (kind, entries, messages)
            assert [message_text(message) for message in messages if message['role'] == 'user'] == ['first', 'second'], (kind, messages)
        else:
            assert len(compactions) == 1 and 'checkpoint' in compactions[0]['summary'], (kind, [entry['type'] for entry in entries])
            compacted = compactions[0]
            assert compacted['tokensBefore'] == 101, (kind, compacted)
            assert any(entry['id'] == compacted['firstKeptEntryId'] and entry['type'] == 'message' for entry in entries), (kind, compacted)
            assert any(message['role'] == 'compactionSummary' and 'checkpoint' in message['summary'] for message in messages), (kind, messages)
            if not json_resume:
                rpc.prompt('third')
            assert 'checkpoint' in json.dumps(fixture.requests[-1]['messages'])
    finally:
        rpc.close()

for kind in ('pi', 'julia'):
    if os.environ.get('JF_HEADLESS_KIND', kind) != kind:
        continue
    for failure, json_resume in ((False, False), (False, True), (True, False)):
        if os.environ.get('JF_MANUAL_TEXT_CASE', 'all') not in ('all', 'failure' if failure else 'json' if json_resume else 'rpc'):
            continue
        with tempfile.TemporaryDirectory(prefix='jf-manual-text-') as tmp:
            root = Path(tmp)
            fixture = Fixture()
            try:
                run(kind, root, fixture, setup(root, fixture), failure, json_resume)
            finally:
                fixture.close()
print('manual text history passed')
