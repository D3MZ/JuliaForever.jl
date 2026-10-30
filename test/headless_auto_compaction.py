import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

project, julia, pi = Path(sys.argv[1]).resolve(), sys.argv[2], Path(sys.argv[3]).resolve()

class Fixture:
    def __init__(self):
        self.requests = []
        self.release = threading.Event()
        self.release.set()
        self.arrived = threading.Event()
        self.gated_user = None
        self.fail_summary = False
        self.overflow = False
        self.tool = False
        self.counts = {}
        fixture = self
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                content = str(body['messages'][-1].get('content', ''))
                summary = '<conversation>' in content or 'Summarize this conversation' in content or '# Conversation' in content and '# Instructions' in content
                user = next((name for name in ('first', 'second', 'third', 'fourth', 'overflow') if name in content), '')
                fixture.requests.append({'summary': summary, 'messages': body['messages'], 'user': user, 'model': body['model']})
                if summary or user == fixture.gated_user:
                    fixture.arrived.set()
                    fixture.release.wait(timeout=60)
                if user == 'overflow' and fixture.overflow and not summary and 'checkpoint' not in json.dumps(body['messages']):
                    data = json.dumps({'error': {'message': 'context length exceeded', 'type': 'invalid_request_error', 'code': 'context_length_exceeded'}}).encode()
                    self.send_response(413)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return
                answer = 'checkpoint' if summary else 'reply:' + user
                finish = 'length' if summary and fixture.fail_summary else 'stop'
                tool_call = fixture.tool and user == 'third' and not summary and body['messages'][-1]['role'] == 'user'
                if tool_call:
                    finish = 'tool_calls'
                count = 10 if summary else fixture.counts.get(user, {'first': 100, 'second': 101}.get(user, 50))
                usage = {'prompt_tokens': count, 'completion_tokens': 0, 'total_tokens': count}
                base = {'id': 'chatcmpl-fixture', 'created': 1, 'model': body['model']}
                if body.get('stream'):
                    base['object'] = 'chat.completion.chunk'
                    delta = {'role': 'assistant', 'content': answer}
                    if tool_call:
                        delta = {'role': 'assistant', 'tool_calls': [{'index': 0, 'id': 'read-large', 'type': 'function', 'function': {'name': 'read', 'arguments': json.dumps({'path': 'target.txt'})}}]}
                    chunks = [dict(base, choices=[{'index': 0, 'delta': delta, 'finish_reason': None}]), dict(base, choices=[{'index': 0, 'delta': {}, 'finish_reason': finish}]), dict(base, choices=[], usage=usage)]
                    data = ''.join('data: ' + json.dumps(chunk) + '\n\n' for chunk in chunks) + 'data: [DONE]\n\n'
                    kind = 'text/event-stream'
                else:
                    base['object'] = 'chat.completion'
                    data = json.dumps(dict(base, choices=[{'index': 0, 'message': {'role': 'assistant', 'content': answer}, 'finish_reason': finish}], usage=usage))
                    kind = 'application/json'
                data = data.encode()
                self.send_response(200)
                self.send_header('Content-Type', kind)
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                try:
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.release.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    @property
    def base(self):
        return f'http://127.0.0.1:{self.server.server_port}/v1'

def setup(root, fixture):
    agent = root / 'agent'
    agent.mkdir()
    model = {'id': 'small', 'name': 'Small', 'contextWindow': 1000, 'maxTokens': 64}
    (agent / 'models.json').write_text(json.dumps({'providers': {'fixture': {'api': 'openai-completions', 'apiKey': 'synthetic', 'baseUrl': fixture.base, 'models': [model]}}}))
    settings = {'compaction': {'reserveTokens': 900, 'keepRecentTokens': 5}, 'retry': {'enabled': False}, 'theme': 'dark'}
    (agent / 'settings.json').write_text(json.dumps(settings))
    env = dict(os.environ, HOME=str(root), USERPROFILE=str(root), PI_CODING_AGENT_DIR=str(agent), PI_SOURCE=str(pi), PI_OFFLINE='1', OPENAI_API_KEY='synthetic', JF_INSTRUCTIONS_DIR=str(root), TERM='dumb')
    for key in ('OPENAI_BASE_URL', 'OPENROUTER_API_KEY', 'ANTHROPIC_API_KEY', 'GEMINI_API_KEY'):
        env.pop(key, None)
    return env

def command(kind, mode, root, args=()):
    sessiondir = root / 'sessions'
    common = ['--mode', mode, '--session-dir', str(sessiondir), '--provider', 'fixture', '--model', 'small']
    if kind == 'pi':
        return ['node', str(project / 'test/headless_reference.mjs'), str(pi), *common, '--approve', *args]
    return [julia, '--startup-file=no', '--compiled-modules=existing', f'--project={project}', '-m', 'JuliaForever', *common, *args]

def records(output):
    return [json.loads(line) for line in output.splitlines() if line.strip()]

def message_text(message):
    content = message.get('content', '')
    return content if isinstance(content, str) else ''.join(item.get('text', '') for item in content if isinstance(item, dict))

def run_json(kind, root, fixture, env):
    process = subprocess.run(command(kind, 'json', root, ['first', 'second', 'third']), cwd=root, env=env, input='', text=True, capture_output=True, timeout=120)
    assert process.returncode == 0, (kind, process.returncode, process.stderr)
    events = records(process.stdout)
    types = [event['type'] for event in events]
    assert types.count('compaction_start') == types.count('compaction_end') == 1, (kind, types, process.stderr)
    start, end = types.index('compaction_start'), types.index('compaction_end')
    assert events[start]['reason'] == 'threshold' and events[end]['reason'] == 'threshold'
    assert events[end]['aborted'] is False and events[end]['willRetry'] is False
    assert events[end]['result']['summary'] == 'checkpoint'
    assert events[end]['result']['tokensBefore'] == 101
    assert events[end]['result']['firstKeptEntryId']
    assert types[start - 1] == 'agent_end' and types[end + 1] == 'agent_settled', (kind, types[start-2:end+3])
    assert [request['summary'] for request in fixture.requests] == [False, False, True, False], (kind, fixture.requests)
    assert 'checkpoint' in json.dumps(fixture.requests[-1]['messages'])
    return events

def run_overflow(kind, root, fixture, env):
    fixture.overflow = True
    process = subprocess.run(command(kind, 'json', root, ['first', 'overflow']), cwd=root, env=env, input='', text=True, capture_output=True, timeout=120)
    assert process.returncode == 0, (kind, process.returncode, process.stderr)
    events = records(process.stdout)
    types = [event['type'] for event in events]
    start = types.index('compaction_start')
    end = types.index('compaction_end')
    assert events[start]['reason'] == events[end]['reason'] == 'overflow'
    assert 'checkpoint' in events[end]['result']['summary'] and events[end]['willRetry'] and not events[end]['aborted'], (kind, events[end])
    visible = [event['type'] for event in events if event['type'] != 'entry_appended']
    start, end = visible.index('compaction_start'), visible.index('compaction_end')
    assert visible[start - 1] == 'agent_end' and visible[end + 1] == 'agent_start', (kind, visible[start-3:end+4])
    assert [request['summary'] for request in fixture.requests] == [False, False, True, False]
    assert 'checkpoint' in json.dumps(fixture.requests[-1]['messages'])

class RPC:
    def __init__(self, kind, root, fixture, env, args=()):
        self.kind = kind
        self.stderr = root / 'rpc.stderr'
        self.err = self.stderr.open('w+')
        self.process = subprocess.Popen(command(kind, 'rpc', root, args), cwd=root, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.err, text=True, bufsize=1)
        self.channel = queue.Queue()
        self.events = []
        def read():
            try:
                for line in self.process.stdout:
                    self.channel.put(json.loads(line))
            finally:
                self.channel.put(None)
        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()

    def send(self, value):
        self.process.stdin.write(json.dumps(value) + '\n')
        self.process.stdin.flush()

    def until(self, predicate):
        while True:
            try:
                event = self.channel.get(timeout=75)
            except queue.Empty:
                raise AssertionError((self.kind, 'timed out', self.events[-12:], self.stderr.read_text()))
            if event is None:
                raise AssertionError((self.kind, 'exited', self.process.poll(), self.events[-12:], self.stderr.read_text()))
            self.events.append(event)
            if predicate(event):
                return event

    def reply(self, id):
        return self.until(lambda event: event.get('id') == id and event.get('type') == 'response')

    def ask(self, id, kind, **fields):
        self.send(dict(id=id, type=kind, **fields))
        return self.reply(id)

    def prompt(self, text):
        self.send({'id': 'prompt-' + text, 'type': 'prompt', 'message': text})
        event = self.until(lambda event: event.get('type') == 'agent_settled')
        assert not event['aborted'], (self.kind, event)

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise AssertionError((self.kind, 'did not exit'))
        self.reader.join(timeout=5)
        self.err.close()
        assert self.process.returncode == 0, (self.kind, self.process.returncode, self.stderr.read_text())

def run_rpc(kind, root, fixture, env):
    rpc = RPC(kind, root, fixture, env)
    try:
        initial = rpc.ask('initial', 'get_state')['data']
        assert initial['autoCompactionEnabled'] and not initial['isCompacting']
        assert rpc.ask('disable', 'set_auto_compaction', enabled=False)['success']
        assert not rpc.ask('disabled', 'get_state')['data']['autoCompactionEnabled']
        rpc.prompt('first')
        rpc.prompt('second')
        assert not any(event['type'] == 'compaction_start' for event in rpc.events)
        assert rpc.ask('enable', 'set_auto_compaction', enabled=True)['success']
        assert rpc.ask('enabled', 'get_state')['data']['autoCompactionEnabled']
        fixture.release.clear()
        rpc.send({'id': 'prompt-third', 'type': 'prompt', 'message': 'third'})
        start = rpc.until(lambda event: event['type'] == 'compaction_start')
        assert start['reason'] == 'threshold'
        assert rpc.ask('queued', 'follow_up', message='fourth')['success']
        during = rpc.ask('during', 'get_state')['data']
        assert during['isCompacting'] and during['isStreaming'] and during['pendingMessageCount'] == 1, (kind, during)
        fixture.release.set()
        end = rpc.until(lambda event: event['type'] == 'compaction_end')
        assert not end['aborted'] and not end['willRetry'] and end['result']['summary'] == 'checkpoint'
        assert end['result']['tokensBefore'] == 101 and end['result']['firstKeptEntryId']
        rpc.until(lambda event: event['type'] == 'agent_settled')
        messages = rpc.ask('messages', 'get_messages')['data']['messages']
        assert any(message['role'] == 'compactionSummary' and message['summary'] == 'checkpoint' for message in messages), (kind, messages)
        assert any(message['role'] == 'user' and message_text(message) == 'third' for message in messages)
        assert any(message['role'] == 'user' and message_text(message) == 'fourth' for message in messages)
        entries = rpc.ask('entries', 'get_entries')['data']['entries']
        compaction = [entry for entry in entries if entry['type'] == 'compaction']
        assert len(compaction) == 1 and compaction[0]['summary'] == 'checkpoint', (kind, compaction)
        assert compaction[0]['firstKeptEntryId'] == end['result']['firstKeptEntryId']
        assert any(entry['id'] == compaction[0]['firstKeptEntryId'] for entry in entries)
        assert [request['summary'] for request in fixture.requests] == [False, False, True, False, False]
        assert 'checkpoint' in json.dumps(fixture.requests[-1]['messages'])
        stats = rpc.ask('stats', 'get_session_stats')['data']
        assert stats['userMessages'] == stats['assistantMessages'] == 4 and stats['tokens']['input'] == 311, (kind, stats)
        saved = rpc.ask('saved', 'get_state')['data']['sessionFile']
        assert rpc.ask('new-reopen', 'new_session')['success']
        assert rpc.ask('reopen', 'switch_session', sessionPath=saved)['success']
        reopened = rpc.ask('reopened-messages', 'get_messages')['data']['messages']
        assert any(message['role'] == 'compactionSummary' and message['summary'] == 'checkpoint' for message in reopened), (kind, reopened)
        restored = rpc.ask('reopened-entries', 'get_entries')['data']['entries']
        assert any(entry['type'] == 'compaction' and entry['firstKeptEntryId'] == end['result']['firstKeptEntryId'] for entry in restored)

        assert rpc.ask('new-after-turn', 'new_session')['success']
        rpc.prompt('first')
        fixture.release.clear()
        rpc.send({'id': 'post-prompt', 'type': 'prompt', 'message': 'second'})
        rpc.until(lambda event: event['type'] == 'compaction_start')
        assert rpc.ask('post-queue', 'follow_up', message='fourth')['success']
        fixture.release.set()
        completed = rpc.until(lambda event: event['type'] == 'compaction_end')
        assert completed['result']['summary'] == 'checkpoint' and not completed['aborted'], (kind, completed)
        rpc.until(lambda event: event['type'] == 'agent_settled')
        postmessages = rpc.ask('post-messages', 'get_messages')['data']['messages']
        assert any(message['role'] == 'user' and message_text(message) == 'fourth' for message in postmessages), (kind, postmessages)

        assert rpc.ask('new-post-cancel', 'new_session')['success']
        rpc.prompt('first')
        fixture.release.clear()
        rpc.send({'id': 'post-cancel-prompt', 'type': 'prompt', 'message': 'second'})
        rpc.until(lambda event: event['type'] == 'compaction_start')
        rpc.send({'id': 'post-abort', 'type': 'abort'})
        stopped = rpc.until(lambda event: event['type'] == 'compaction_end')
        assert stopped['aborted'] and not stopped['willRetry'], (kind, stopped)
        assert rpc.until(lambda event: event['type'] == 'agent_settled')['aborted']
        assert rpc.reply('post-abort')['success']
        fixture.release.set()

        assert rpc.ask('new-cancel', 'new_session')['success']
        assert rpc.ask('disable-cancel', 'set_auto_compaction', enabled=False)['success']
        rpc.prompt('first')
        rpc.prompt('second')
        assert rpc.ask('enable-cancel', 'set_auto_compaction', enabled=True)['success']
        fixture.arrived.clear()
        fixture.release.clear()
        rpc.send({'id': 'cancel-prompt', 'type': 'prompt', 'message': 'third'})
        rpc.until(lambda event: event['type'] == 'compaction_start')
        rpc.send({'id': 'abort', 'type': 'abort'})
        stopped = rpc.until(lambda event: event['type'] == 'compaction_end')
        assert stopped['aborted'] and not stopped['willRetry'] and 'result' not in stopped, (kind, stopped)
        assert rpc.until(lambda event: event['type'] == 'agent_settled')['aborted']
        assert rpc.reply('abort')['success']
        fixture.release.set()
        entries = rpc.ask('cancel-entries', 'get_entries')['data']['entries']
        assert not any(entry['type'] == 'compaction' for entry in entries)

        assert rpc.ask('new-failure', 'new_session')['success']
        assert rpc.ask('disable-failure', 'set_auto_compaction', enabled=False)['success']
        rpc.prompt('first')
        rpc.prompt('second')
        assert rpc.ask('enable-failure', 'set_auto_compaction', enabled=True)['success']
        fixture.fail_summary = True
        before = len(rpc.events)
        rpc.prompt('third')
        fixture.fail_summary = False
        failed = [event for event in rpc.events[before:] if event['type'] == 'compaction_end']
        assert len(failed) == 1 and not failed[0]['aborted'] and 'errorMessage' in failed[0] and 'result' not in failed[0], (kind, failed)
        assert 'checkpoint' not in json.dumps(fixture.requests[-1]['messages'])

        entries = rpc.ask('failure-entries', 'get_entries')['data']['entries']
        assert not any(entry['type'] == 'compaction' for entry in entries)

        for enabled in (False, True):
            assert rpc.ask('new-toggle-' + str(enabled), 'new_session')['success']
            assert rpc.ask('start-toggle-' + str(enabled), 'set_auto_compaction', enabled=not enabled)['success']
            rpc.prompt('first')
            fixture.gated_user = 'second'
            fixture.arrived.clear()
            fixture.release.clear()
            before = len(rpc.events)
            rpc.send({'id': 'live-' + str(enabled), 'type': 'prompt', 'message': 'second'})
            assert fixture.arrived.wait(60), (kind, 'second request did not arrive')
            assert rpc.ask('toggle-' + str(enabled), 'set_auto_compaction', enabled=enabled)['success']
            fixture.gated_user = None
            fixture.release.set()
            rpc.until(lambda event: event['type'] == 'agent_settled')
            starts = [event for event in rpc.events[before:] if event['type'] == 'compaction_start']
            assert len(starts) == int(enabled), (kind, enabled, starts)
        assert rpc.ask('final-enable', 'set_auto_compaction', enabled=True)['success']
        if kind == 'julia':
            settings = root / 'agent/settings.json'
            original = settings.read_bytes()
            lock = root / 'agent/settings.json.lock'
            lock.mkdir()
            try:
                assert not rpc.ask('locked', 'set_auto_compaction', enabled=False)['success']
                assert settings.read_bytes() == original
            finally:
                lock.rmdir()
            settings.write_text('{')
            assert not rpc.ask('invalid', 'set_auto_compaction', enabled=False)['success']
            assert settings.read_text() == '{'
            settings.write_bytes(original)
    finally:
        fixture.release.set()
        rpc.close()
    settings = json.loads((root / 'agent/settings.json').read_text())
    assert settings['theme'] == 'dark' and settings['compaction']['enabled'] is True and settings['compaction']['keepRecentTokens'] == 5, (kind, settings)

def run_cross_mode(kind, root, fixture, env, json_first=False):
    path = root / 'agent/settings.json'
    settings = json.loads(path.read_text())
    settings['compaction']['enabled'] = False
    path.write_text(json.dumps(settings))
    for text, options in (('first', []), ('second', ['--continue'])):
        process = subprocess.run(command(kind, 'text', root, [*options, text]), cwd=root, env=env, input='', text=True, capture_output=True, timeout=120)
        assert process.returncode == 0 and 'reply:' + text in process.stdout, (kind, process.stdout, process.stderr)
    if json_first:
        settings['compaction']['enabled'] = True
        path.write_text(json.dumps(settings))
        process = subprocess.run(command(kind, 'json', root, ['--continue', 'third']), cwd=root, env=env, input='', text=True, capture_output=True, timeout=120)
        assert process.returncode == 0, (kind, process.stderr)
        end = next(event for event in records(process.stdout) if event['type'] == 'compaction_end')
    rpc = RPC(kind, root, fixture, env, ['--continue'])
    try:
        if not json_first:
            assert rpc.ask('cross-enable', 'set_auto_compaction', enabled=True)['success']
            rpc.prompt('third')
            end = next(event for event in rpc.events if event['type'] == 'compaction_end')
        firstkept = end['result']['firstKeptEntryId']
        entries = rpc.ask('cross-entries', 'get_entries')['data']['entries']
        assert any(entry['id'] == firstkept for entry in entries), (kind, firstkept, entries)
        assert any(entry['type'] == 'compaction' and entry['firstKeptEntryId'] == firstkept for entry in entries)
        messages = rpc.ask('cross-messages', 'get_messages')['data']['messages']
        assert any(message['role'] == 'compactionSummary' and message['summary'] == 'checkpoint' for message in messages)
    finally:
        rpc.close()

def run_model_switch(kind, root, fixture, env):
    models = root / 'agent/models.json'
    config = json.loads(models.read_text())
    config['providers']['other'] = {'api': 'openai-completions', 'apiKey': 'synthetic', 'baseUrl': fixture.base, 'models': [{'id': 'large', 'name': 'Large', 'contextWindow': 5000, 'maxTokens': 64}]}
    models.write_text(json.dumps(config))
    path = root / 'agent/settings.json'
    settings = json.loads(path.read_text())
    settings['compaction']['enabled'] = False
    path.write_text(json.dumps(settings))
    fixture.counts['third'] = 101
    rpc = RPC(kind, root, fixture, env)
    try:
        rpc.prompt('first')
        rpc.prompt('second')
        assert rpc.ask('large', 'set_model', provider='other', modelId='large')['success']
        assert rpc.ask('enable-large', 'set_auto_compaction', enabled=True)['success']
        before = len(rpc.events)
        rpc.prompt('third')
        assert not any(event['type'] == 'compaction_start' for event in rpc.events[before:])
        assert rpc.ask('small', 'set_model', provider='fixture', modelId='small')['success']
        before = len(rpc.events)
        rpc.prompt('fourth')
        ends = [event for event in rpc.events[before:] if event['type'] == 'compaction_end']
        assert len(ends) == 1 and ends[0]['reason'] == 'threshold' and 'checkpoint' in ends[0]['result']['summary'], (kind, ends)
        assert [request['model'] for request in fixture.requests[-2:]] == ['small', 'small']
    finally:
        rpc.close()

def check_tool_compaction(kind, events, fixture):
    types = [event['type'] for event in events if event['type'] != 'entry_appended']
    assert 'compaction_start' in types and 'compaction_end' in types, (kind, types, fixture.requests)
    start, end = types.index('compaction_start'), types.index('compaction_end')
    assert types[start - 1] == 'turn_end' and types[end + 1] == 'turn_start', (kind, types)
    assert 'agent_end' not in types[:end], (kind, types)
    compacted = next(event for event in events if event['type'] == 'compaction_end')
    assert compacted['reason'] == 'threshold' and not compacted['aborted'] and not compacted['willRetry']
    assert 'checkpoint' in compacted['result']['summary'] and compacted['result']['tokensBefore'] == 150, (kind, compacted)
    flags = [request['summary'] for request in fixture.requests]
    assert flags[:3] == [False, False, False] and flags[3:-1] and all(flags[3:-1]) and not flags[-1], (kind, flags)
    messages = fixture.requests[-1]['messages']
    assert 'checkpoint' in json.dumps(messages) and 'x' * 400 in json.dumps(messages), (kind, messages)
    assert any(message.get('role') == 'tool' for message in messages), (kind, messages)
    return compacted

def run_tool_compaction(kind, root, fixture, env, json_mode=False):
    fixture.tool = True
    fixture.counts.update(first=50, second=50, third=50)
    (root / 'target.txt').write_text('x' * 400)
    if json_mode:
        process = subprocess.run(command(kind, 'json', root, ['first', 'second', 'third']), cwd=root, env=env, input='', text=True, capture_output=True, timeout=120)
        assert process.returncode == 0, (kind, process.returncode, process.stderr)
        events = records(process.stdout)
        settled = [index for index, event in enumerate(events) if event['type'] == 'agent_settled']
        check_tool_compaction(kind, events[settled[1] + 1:], fixture)
        return
    rpc = RPC(kind, root, fixture, env)
    try:
        rpc.prompt('first')
        rpc.prompt('second')
        before = len(rpc.events)
        rpc.prompt('third')
        compacted = check_tool_compaction(kind, rpc.events[before:], fixture)
        kept = compacted['result']['firstKeptEntryId']
        entries = rpc.ask('tool-entries', 'get_entries')['data']['entries']
        assert any(entry['id'] == kept for entry in entries)
        assert any(entry['type'] == 'compaction' and entry['firstKeptEntryId'] == kept for entry in entries)
        saved = rpc.ask('tool-saved', 'get_state')['data']['sessionFile']
        assert rpc.ask('tool-new', 'new_session')['success']
        assert rpc.ask('tool-reopen', 'switch_session', sessionPath=saved)['success']
        messages = rpc.ask('tool-messages', 'get_messages')['data']['messages']
        assert any(message['role'] == 'compactionSummary' and 'checkpoint' in message['summary'] for message in messages)
        assert any(message['role'] == 'toolResult' and 'x' * 400 in message_text(message) for message in messages), (kind, messages)
    finally:
        rpc.close()

def run_tool_controls(kind, root, fixture, env):
    fixture.tool = True
    fixture.counts.update(first=50, second=50, third=50)
    (root / 'target.txt').write_text('x' * 400)
    rpc = RPC(kind, root, fixture, env)
    try:
        rpc.prompt('first')
        rpc.prompt('second')
        fixture.release.clear()
        fixture.arrived.clear()
        rpc.send({'id': 'tool-queue-prompt', 'type': 'prompt', 'message': 'third'})
        assert rpc.reply('tool-queue-prompt')['success']
        assert fixture.arrived.wait(60), (kind, 'summary did not start')
        assert rpc.ask('tool-queue-state', 'get_state')['data']['isCompacting']
        assert rpc.ask('tool-queue', 'steer', message='queued')['success']
        fixture.release.set()
        rpc.until(lambda event: event['type'] == 'agent_settled')
        request = fixture.requests[-1]['messages']
        assert any(message.get('role') == 'user' and message_text(message) == 'queued' for message in request), (kind, request)
        assert 'checkpoint' in json.dumps(request) and 'x' * 400 in json.dumps(request)

        assert rpc.ask('tool-cancel-new', 'new_session')['success']
        rpc.prompt('first')
        rpc.prompt('second')
        fixture.release.clear()
        fixture.arrived.clear()
        rpc.send({'id': 'tool-cancel-prompt', 'type': 'prompt', 'message': 'third'})
        assert rpc.reply('tool-cancel-prompt')['success']
        assert fixture.arrived.wait(60), (kind, 'summary did not start')
        rpc.send({'id': 'tool-abort', 'type': 'abort'})
        stopped = rpc.until(lambda event: event['type'] == 'compaction_end')
        assert stopped['aborted'] and not stopped['willRetry'] and 'result' not in stopped, (kind, stopped)
        assert rpc.until(lambda event: event['type'] == 'agent_settled')['aborted']
        assert rpc.reply('tool-abort')['success']
        fixture.release.set()
        entries = rpc.ask('tool-cancel-entries', 'get_entries')['data']['entries']
        assert not any(entry['type'] == 'compaction' for entry in entries)

        assert rpc.ask('tool-failure-new', 'new_session')['success']
        rpc.prompt('first')
        rpc.prompt('second')
        fixture.fail_summary = True
        before = len(rpc.events)
        rpc.prompt('third')
        failed = [event for event in rpc.events[before:] if event['type'] == 'compaction_end']
        assert len(failed) == 1 and not failed[0]['aborted'] and 'errorMessage' in failed[0] and 'result' not in failed[0], (kind, failed)
        assert 'checkpoint' not in json.dumps(fixture.requests[-1]['messages'])

        fixture.fail_summary = False
        assert rpc.ask('tool-toggle-new', 'new_session')['success']
        assert rpc.ask('tool-toggle-off', 'set_auto_compaction', enabled=False)['success']
        rpc.prompt('first')
        rpc.prompt('second')
        fixture.gated_user = 'third'
        fixture.release.clear()
        fixture.arrived.clear()
        before = len(rpc.events)
        rpc.send({'id': 'tool-toggle-prompt', 'type': 'prompt', 'message': 'third'})
        assert rpc.reply('tool-toggle-prompt')['success']
        assert fixture.arrived.wait(60), (kind, 'model request did not start')
        assert rpc.ask('tool-toggle-on', 'set_auto_compaction', enabled=True)['success']
        fixture.gated_user = None
        fixture.release.set()
        rpc.until(lambda event: event['type'] == 'agent_settled')
        assert any(event['type'] == 'compaction_end' and event['reason'] == 'threshold' and not event['aborted'] for event in rpc.events[before:])
    finally:
        fixture.release.set()
        rpc.close()

with tempfile.TemporaryDirectory(prefix='jf-headless-auto-') as tmp:
    base = Path(tmp)
    for mode in ('json', 'overflow', 'rpc', 'cross', 'cross-json', 'switch', 'tool', 'tool-json', 'tool-controls'):
        if os.environ.get('JF_HEADLESS_CASE', mode) != mode:
            continue
        for kind in ('pi', 'julia'):
            if os.environ.get('JF_HEADLESS_KIND', kind) != kind:
                continue
            root = base / f'{mode}-{kind}'
            root.mkdir()
            fixture = Fixture()
            try:
                env = setup(root, fixture)
                if mode == 'json':
                    run_json(kind, root, fixture, env)
                elif mode == 'overflow':
                    run_overflow(kind, root, fixture, env)
                elif mode == 'cross':
                    run_cross_mode(kind, root, fixture, env)
                elif mode == 'cross-json':
                    run_cross_mode(kind, root, fixture, env, json_first=True)
                elif mode == 'switch':
                    run_model_switch(kind, root, fixture, env)
                elif mode == 'tool':
                    run_tool_compaction(kind, root, fixture, env)
                elif mode == 'tool-json':
                    run_tool_compaction(kind, root, fixture, env, json_mode=True)
                elif mode == 'tool-controls':
                    run_tool_controls(kind, root, fixture, env)
                else:
                    run_rpc(kind, root, fixture, env)
            finally:
                fixture.close()
print('Pi JSON and RPC automatic compaction passed')
