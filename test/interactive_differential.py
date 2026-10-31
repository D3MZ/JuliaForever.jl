import argparse
from concurrent.futures import ThreadPoolExecutor
import html
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


SGR = re.compile(r'\x1b\[([0-9;:]*)m')
COUNT = re.compile(r'\((\d+)/(\d+)\)')
SELECTION = re.compile(r'^\s*→\s*(.+?)\s*$')
DEFAULT = (None, None, False, False, False, False, False)


def color(parts, index):
    kind = parts[index + 1] if index + 1 < len(parts) else -1
    if kind == 5 and index + 2 < len(parts):
        return f'index:{parts[index + 2]}', index + 2
    if kind == 2 and index + 4 < len(parts):
        return '#%02x%02x%02x' % tuple(parts[index + 2:index + 5]), index + 4
    return None, index


def attributes(state, params):
    values = [int(value) if value else 0 for value in params.replace(':', ';').split(';')]
    values = values or [0]
    fg, bg, bold, dim, italic, underline, inverse = state
    index = 0
    while index < len(values):
        code = values[index]
        if code == 0:
            fg, bg, bold, dim, italic, underline, inverse = DEFAULT
        elif code == 1: bold = True
        elif code == 2: dim = True
        elif code == 3: italic = True
        elif code == 4: underline = True
        elif code == 7: inverse = True
        elif code == 22: bold = dim = False
        elif code == 23: italic = False
        elif code == 24: underline = False
        elif code == 27: inverse = False
        elif code == 39: fg = None
        elif code == 49: bg = None
        elif 30 <= code <= 37: fg = f'index:{code - 30}'
        elif 90 <= code <= 97: fg = f'index:{code - 90 + 8}'
        elif 40 <= code <= 47: bg = f'index:{code - 40}'
        elif 100 <= code <= 107: bg = f'index:{code - 100 + 8}'
        elif code in (38, 48):
            value, index = color(values, index)
            if code == 38: fg = value
            else: bg = value
        index += 1
    return fg, bg, bold, dim, italic, underline, inverse


def parse(capture):
    rows = [[]]
    state = DEFAULT
    offset = 0
    for match in SGR.finditer(capture):
        for char in capture[offset:match.start()]:
            if char == '\n': rows.append([])
            elif char != '\r': rows[-1].append((char, state))
        state = attributes(state, match.group(1))
        offset = match.end()
    for char in capture[offset:]:
        if char == '\n': rows.append([])
        elif char != '\r': rows[-1].append((char, state))
    if rows and not rows[-1]: rows.pop()
    return rows


def cell_width(char):
    return 0 if unicodedata.combining(char) or unicodedata.category(char) in ('Mn', 'Me', 'Cf') else 2 if unicodedata.east_asian_width(char) in ('W', 'F') else 1


def pad(rows, width, height):
    result = []
    for row in rows:
        missing = max(0, width - sum(cell_width(char) for char, _ in row))
        result.append(row + [(' ', DEFAULT)] * missing)
    result.extend([[(' ', DEFAULT)] * width for _ in range(max(0, height - len(result)))])
    return result


def text(rows):
    return '\n'.join(''.join(char for char, _ in row) for row in rows)


def compare(pi, jf):
    differences = []
    for index in range(max(len(pi), len(jf))):
        left = pi[index] if index < len(pi) else []
        right = jf[index] if index < len(jf) else []
        if ''.join(char for char, _ in left) != ''.join(char for char, _ in right):
            differences.append(f'text differs at row {index + 1}')
            break
    for index, (left, right) in enumerate(zip(pi, jf)):
        for column, (a, b) in enumerate(zip(left, right)):
            if a[0] == b[0] and a[1] != b[1]:
                differences.append(f'style differs at row {index + 1}, column {column + 1}')
                return differences
    return differences


def selected(screen):
    count = COUNT.search(screen)
    if not count: return None
    for line in screen.splitlines():
        match = SELECTION.match(line)
        if match:
            return re.split(r'\s{2,}', match.group(1).strip(), maxsplit=1)[0], int(count.group(1)), int(count.group(2))
    return None



def setting(screen):
    count = COUNT.search(screen)
    if not count: return None
    for line in screen.splitlines():
        match = re.match(r'^\s*→\s*(.*?)\s{2,}(\S.*?)\s*$', line)
        if match:
            return match.group(1).strip(), match.group(2).strip(), int(count.group(1)), int(count.group(2))
    return None

def report(name, pi, jf, required=None):
    differences = compare(pi, jf)
    if required and required not in text(pi):
        differences.insert(0, f'reference did not display {required!r}')
    elif required and required not in text(jf):
        differences.insert(0, f'missing in JF: {required}')
    return {'name': name, 'match': not differences, 'differences': differences}


PALETTE = (
    '#000000', '#cd0000', '#00cd00', '#cdcd00', '#0000ee', '#cd00cd', '#00cdcd', '#e5e5e5',
    '#7f7f7f', '#ff0000', '#00ff00', '#ffff00', '#5c5cff', '#ff00ff', '#00ffff', '#ffffff',
)


def csscolor(value, default):
    if value is None: return default
    if not value.startswith('index:'): return value
    index = int(value[6:])
    if index < 16: return PALETTE[index]
    if index < 232:
        index -= 16
        levels = [0, 95, 135, 175, 215, 255]
        return '#%02x%02x%02x' % (levels[index // 36], levels[(index // 6) % 6], levels[index % 6])
    level = min(255, 8 + (index - 232) * 10)
    return '#%02x%02x%02x' % (level, level, level)


def css(state):
    fg, bg, bold, dim, italic, underline, inverse = state
    fg, bg = csscolor(fg, '#e5e5e5'), csscolor(bg, '#16181d')
    if inverse: fg, bg = bg, fg
    return ';'.join((f'color:{fg}', f'background-color:{bg}', f'font-weight:{"bold" if bold else "normal"}', f'font-style:{"italic" if italic else "normal"}', f'text-decoration:{"underline" if underline else "none"}', f'opacity:{"0.65" if dim else "1"}'))


def screen_html(rows, cursor=None):
    output = []
    visible, cx, cy = map(int, cursor.split()) if cursor else (0, 0, 0)
    for y, row in enumerate(rows):
        group = []
        previous = None
        x = 0
        for char, state in row:
            width = cell_width(char)
            current = state, bool(visible and cy == y and x <= cx < x + width)
            if current != previous and group:
                style, highlighted = previous
                output.append(f'<span class="{"cursor" if highlighted else ""}" style="{css(style)}">{html.escape("".join(group))}</span>')
                group = []
            group.append(char)
            previous = current
            x += width
        if group:
            style, highlighted = previous
            output.append(f'<span class="{"cursor" if highlighted else ""}" style="{css(style)}">{html.escape("".join(group))}</span>')
        output.append('\n')
    return ''.join(output)


def page(name, pi, jf, differences, font, cursors=None, dimensions=None):
    title = html.escape(name)
    description = html.escape('; '.join(differences) if differences else 'Screens match')
    family = html.escape(font, quote=True)
    cursors = cursors or {}
    dimensions = dimensions or {}
    def size(name):
        width, height = dimensions.get(name, (0, 0))
        return f'width:{width}ch;height:{height * 18}px;overflow:hidden' if width and height else ''
    return f'''<!doctype html><meta charset="utf-8"><title>{title}</title>
<style>html,body{{margin:0;background:#101216;color:#f1f1f1}}body{{padding:12px;font:14px sans-serif}}
h1{{font-size:17px;margin:0 0 4px}}p{{margin:0 0 10px;color:#f6bd60}}.pair{{display:flex;gap:12px}}
.panel{{flex:none}}h2{{font-size:14px;margin:0 0 5px}}pre{{margin:0;padding:8px;background:#16181d;color:#e5e5e5;font:14px/18px {family};font-variant-ligatures:none;white-space:pre}}.cursor{{outline:1px solid white;outline-offset:-1px}}</style>
<h1>{title}</h1><p>{description}</p><div class="pair"><div class="panel"><h2>Pi</h2><pre style="{size('pi')}">{screen_html(pi, cursors.get('pi'))}</pre></div><div class="panel"><h2>JF</h2><pre style="{size('jf')}">{screen_html(jf, cursors.get('jf'))}</pre></div></div>'''


def cursor_differs(left, right):
    a = tuple(map(int, left.split()))
    b = tuple(map(int, right.split()))
    return a[0] != b[0] or (a[0] and a[1:] != b[1:])


def completion_present(screen, command):
    pattern = re.compile(r'^\s*(?:→\s*|\s{2,})/?' + re.escape(command) + r'(?:\s|$)')
    return any(pattern.match(line) for line in screen.splitlines())


def choice(screen):
    for line in screen.splitlines():
        if '→' in line:
            return line.split('→', 1)[1].strip()
    return None


def depot_path(env):
    return env.get('JULIA_DEPOT_PATH', str(Path(env.get('HOME', str(Path.home()))) / '.julia') + os.pathsep)


def compilation_free(before, after):
    return before == after


def fixture_response(content):
    if isinstance(content, str):
        for prefix, paused in (('latency-', False), ('stream-', True)):
            if content.startswith(prefix):
                return 'fixture-' + content.removeprefix(prefix) + '-first', True, paused
    return 'reply:' + str(content), False, False


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        content = request.get('messages', [{}])[-1].get('content', '')
        if isinstance(content, list):
            content = ''.join(part.get('text', '') for part in content if isinstance(part, dict))
        reply, streaming, paused = fixture_response(content)
        chunks = [({'role': 'assistant', 'content': reply}, None)]
        if streaming: chunks.append(({'content': '-complete'}, None))
        chunks.append(({}, 'stop'))
        events = [dict(id='fixture', object='chat.completion.chunk', created=1, model='fixture', choices=[dict(index=0, delta=delta, finish_reason=finish)]) for delta, finish in chunks]
        payloads = [('data: ' + json.dumps(event) + '\n\n').encode() for event in events]
        payloads.append(b'data: [DONE]\n\n')
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(sum(map(len, payloads))))
        self.end_headers()
        self.wfile.write(payloads[0])
        self.wfile.flush()
        if paused: self.server.stream_gate.wait(timeout=45)
        for payload in payloads[1:]: self.wfile.write(payload)


class Terminals:
    def __init__(self, project, source, julia, directory):
        self.project, self.source, self.julia = Path(project), Path(source), julia
        self.directory = Path(directory)
        self.work = self.directory / 'work'
        self.work.mkdir()
        self.socket = 'jf-ui-' + str(os.getpid())
        self.command = ['tmux', '-f', '/dev/null', '-L', self.socket]
        self.env = dict(os.environ, TMUX_TMPDIR=str(self.directory))
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
        self.server.stream_gate = threading.Event()
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.timings = {}

    def tmux(self, *args, check=True):
        result = subprocess.run([*self.command, *args], env=self.env, text=True, capture_output=True)
        if check and result.returncode:
            raise RuntimeError(f'tmux {args}: {result.stderr.strip()}')
        return result.stdout

    def launch(self, name):
        apphome = self.directory / name
        agent = apphome / 'agent'
        agent.mkdir(parents=True)
        base = f'http://127.0.0.1:{self.server.server_port}/v1'
        settings = {'lastChangelogVersion': '1.4.0', 'retry': {'enabled': False}}
        model = {'id': 'fixture', 'name': 'fixture', 'reasoning': True, 'contextWindow': 10000, 'maxTokens': 2048}
        config = {'providers': {'openai': {'baseUrl': base, 'api': 'openai-completions', 'apiKey': 'not-a-real-api-key', 'models': [model]}}}
        (agent / 'settings.json').write_text(json.dumps(settings))
        (agent / 'models.json').write_text(json.dumps(config))
        env = {key: os.environ[key] for key in ('PATH', 'LANG', 'LC_ALL', 'JULIA_DEPOT_PATH', 'JULIA_NUM_THREADS') if key in os.environ}
        env['JULIA_DEPOT_PATH'] = depot_path(os.environ)
        env.update(HOME=str(apphome), USERPROFILE=str(apphome), PI_SOURCE=str(self.source), PI_CODING_AGENT_DIR=str(agent), PI_OFFLINE='1', PI_TELEMETRY='0', OPENAI_API_KEY='not-a-real-api-key', OPENAI_MODEL='fixture', OPENAI_BASE_URL=base, JF_PROVIDER='openai', JF_INSTRUCTIONS_DIR=str(self.work), JF_SESSION_DIR=str(apphome / 'sessions'), TERM='xterm-256color')
        if name == 'pi':
            process = ['node', str(self.project / 'test/headless_reference.mjs'), str(self.source), '--offline', '--no-extensions', '--no-mcp', '--no-context-files', '--approve', '--provider', 'openai', '--model', 'fixture', '--tui-mode', 'fullscreen', '--session-dir', str(apphome / 'sessions')]
        else:
            env['JULIA_NUM_THREADS'] = '1'
            env['JF_UI_COMPILE_PORT'] = str(apphome / 'compile-port')
            process = [self.julia, '--startup-file=no', '--compiled-modules=existing', f'--project={self.project}', str(self.project / 'test/interactive_compile_clock.jl'), '--tui-mode', 'fullscreen', '--provider', 'openai', '--model', 'fixture', '--session-dir', str(apphome / 'sessions')]
        command = ['env', '-i', *(f'{key}={value}' for key, value in env.items()), *process]
        self.tmux('new-session', '-d', '-s', name, '-x', '100', '-y', '30', '-c', str(self.work), shlex.join(command))
        self.tmux('set-option', '-t', name, 'remain-on-exit', 'on')
        self.tmux('set-option', '-g', 'extended-keys', 'on')

    def capture(self, name, styled=True):
        args = ['capture-pane', '-p', '-N']
        if styled: args.append('-e')
        return self.tmux(*args, '-t', name)

    def cursor(self, name):
        return self.tmux('display-message', '-p', '-t', name, '#{cursor_flag} #{cursor_x} #{cursor_y}').strip()

    def dimensions(self, name):
        return tuple(map(int, self.tmux('display-message', '-p', '-t', name, '#{pane_width} #{pane_height}').split()))

    def alive(self, name):
        return self.tmux('display-message', '-p', '-t', name, '#{pane_dead}').strip() != '1'

    def ready(self, timeout=180):
        pending = {'pi', 'jf'}
        deadline = time.monotonic() + timeout
        while pending and time.monotonic() < deadline:
            for name in tuple(pending):
                screen = self.capture(name, False)
                if not self.alive(name):
                    history = self.tmux('capture-pane', '-p', '-S', '-200', '-t', name)
                    raise RuntimeError(f'{name} exited during startup:\n{history}')
                if ('fixture' in screen and (name == 'pi' or 'fixture | ready' in screen)):
                    self.timings[name] = {}
                    pending.remove(name)
            time.sleep(.05)
        if pending: raise RuntimeError('startup timed out: ' + ', '.join(sorted(pending)))

    def compilation(self):
        port = int((self.directory / 'jf' / 'compile-port').read_text())
        with socket.create_connection(('127.0.0.1', port), timeout=10) as connection:
            with connection.makefile() as reader:
                values = tuple(map(int, reader.readline().split()))
        if len(values) != 2: raise RuntimeError('JF compilation counter did not respond')
        return values

    def key(self, name, *keys):
        self.tmux('send-keys', '-t', name, *keys)

    def type(self, name, value):
        self.tmux('send-keys', '-t', name, '-l', '--', value)
        expected = ('> ' if name == 'jf' else '') + value
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            screen = self.capture(name, False)
            if any(line.strip() == expected for line in screen.splitlines()): return
            if not self.alive(name): self.settle(0)
            time.sleep(.05)
        raise RuntimeError(f'{name} did not finish entering {value!r}:\n{screen}')

    def both(self, *keys):
        for name in ('pi', 'jf'): self.key(name, *keys)

    def send(self, value):
        for name in ('pi', 'jf'): self.type(name, value)
        for name in ('pi', 'jf'): self.key(name, 'Enter')
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            lines = [line.strip() for line in self.capture('jf', False).splitlines() if line.lstrip().startswith('>')]
            if not lines or lines[-1] != '> ' + value: return
            if not self.alive('jf'): self.settle(0)
            time.sleep(.05)

    def settle(self, delay=.2):
        time.sleep(delay)
        for name in ('pi', 'jf'):
            if not self.alive(name):
                history = self.tmux('capture-pane', '-p', '-S', '-200', '-t', name)
                raise RuntimeError(f'{name} exited during comparison:\n{history}')

    def editor_ready(self):
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            screen = self.capture('jf', False)
            lines = [line.strip() for line in screen.splitlines() if line.strip()]
            if '| ready |' in screen and lines and lines[-1].startswith('>'): break
            if not self.alive('jf'): self.settle(0)
            time.sleep(.05)
        else:
            raise RuntimeError('JF did not return to the editor after closing the menu')

    def reset(self):
        self.both('Escape')
        self.editor_ready()
        self.both('C-e', 'C-u')
        self.settle()

    def close(self):
        self.tmux('kill-server', check=False)
        self.server.shutdown()
        self.server.server_close()


class Results:
    def __init__(self, output, font):
        self.output = Path(output).resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        self.states = self.output / 'states'
        self.states.mkdir(exist_ok=True)
        self.font = font
        self.cases = []
        self.errors = []
        self.timings = {}

    def add(self, name, terminals, required=None, missing=None):
        raw = {key: terminals.capture(key) for key in ('pi', 'jf')}
        dimensions = {key: terminals.dimensions(key) for key in ('pi', 'jf')}
        screens = {key: pad(parse(value), *dimensions[key]) for key, value in raw.items()}
        result = report(name, screens['pi'], screens['jf'], required)
        if dimensions['pi'] != dimensions['jf']:
            result['differences'].append(f'terminal size differs: Pi {dimensions["pi"]}, JF {dimensions["jf"]}')
            result['match'] = False
        cursors = {key: terminals.cursor(key) for key in ('pi', 'jf')}
        if cursor_differs(cursors['pi'], cursors['jf']):
            result['differences'].append(f'cursor differs: Pi {cursors["pi"]}, JF {cursors["jf"]}')
            result['match'] = False
        result['cursors'] = cursors
        result['dimensions'] = dimensions
        if missing:
            result['differences'].insert(0, missing)
            result['match'] = False
        slug = re.sub(r'[^a-z0-9]+', '-', name.lower()).strip('-')[:70]
        stem = f'{len(self.cases) + 1:04d}-{slug}'
        for key, value in raw.items():
            (self.states / f'{stem}-{key}.ansi').write_text(value)
        relpage = f'states/{stem}.html'
        (self.output / relpage).write_text(page(name, screens['pi'], screens['jf'], result['differences'], self.font, cursors, dimensions))
        result.update(page=relpage, image=f'states/{stem}.png', pi=text(screens['pi']), jf=text(screens['jf']))
        self.cases.append(result)
        if len(self.cases) % 25 == 0: print(f'Captured {len(self.cases)} terminal states', flush=True)
        return result

    def finish(self):
        coverage = {'tested': ['startup and terminal resizing', 'first fixture response after warm-up and streamed output', 'all pinned Pi built-in command completions', 'model selector', 'settings and their direct submenus', 'thinking, model scope, authentication, trust, session, tree, fork, and resume screens'], 'not_tested': ['compilation-free process startup time', 'V8 compilation during the Pi response', 'every provider or model response', 'extension and authentication flows', 'external sharing, browser, and clipboard actions', 'all nested menu actions or terminal dimensions', 'physical terminal font, ligature, and pixel rendering']}
        result = {'cases': self.cases, 'errors': self.errors, 'timings': self.timings, 'font': self.font, 'coverage': coverage}
        (self.output / 'report.json').write_text(json.dumps(result, indent=2, ensure_ascii=False))
        lines = []
        for case in self.cases:
            status = 'PASS' if case['match'] else 'FAIL'
            name = html.escape(case['name'])
            detail = html.escape('; '.join(case['differences']))
            lines.append(f'<li><strong>{status}</strong> <a href="{case["page"]}">{name}</a> <a href="{case["image"]}">PNG</a> — {detail}</li>')
        errors = ''.join('<li>' + html.escape(error) + '</li>' for error in self.errors)
        timing = html.escape(json.dumps(self.timings, indent=2))
        exclusions = ''.join('<li>' + html.escape(item) + '</li>' for item in coverage['not_tested'])
        document = f'''<!doctype html><meta charset="utf-8"><title>Pi / JF terminal comparison</title><style>body{{font:15px system-ui;max-width:1100px;margin:2em auto;padding:0 1em}}li{{margin:.6em 0}}strong{{color:#b22}}pre{{background:#eee;padding:1em}}</style><h1>Pi / JF terminal comparison</h1><p>{len(self.cases)} captured states; {sum(not case['match'] for case in self.cases)} differ.</p><p>Both panes are reconstructed from terminal cells and ANSI styles using the same font; these are not screenshots of the operating system terminal. Response timing follows warm-up and is reported only when Julia's compilation counters do not change during the measured response; Julia runs with one thread. The timed fixture emits its chunks without a deliberate delay. Pi is also warmed up, but V8 compilation is not measured. Startup screens are compared without reporting compilation-inclusive startup times. A separate streaming check holds its final chunk until both apps show the first chunk or 1.5 seconds have passed. Timing is one local measurement, not a benchmark.</p><pre>{timing}</pre><ul>{errors}</ul><h2>Not covered</h2><ul>{exclusions}</ul><h2>Captured states</h2><ol>{''.join(lines)}</ol>'''
        (self.output / 'index.html').write_text(document)


def wait_text(terminals, name, expected, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        screen = terminals.capture(name, False)
        if expected in screen: return screen
        if not terminals.alive(name):
            terminals.settle(0)
        time.sleep(.05)
    raise RuntimeError(f'{name} did not display {expected!r}:\n{screen}')


def walk_menu(terminals, results, label, required, maximum=300):
    pi = terminals.capture('pi', False)
    current = selected(pi)
    if not current:
        results.add(label, terminals, required=required)
        results.errors.append(f'could not enumerate Pi {label}')
        return
    jf_open = required in terminals.capture('jf', False)
    jf_options = set()
    if jf_open:
        for _ in range(maximum):
            lines = terminals.capture('jf', False).splitlines()
            current_jf = next((line.strip()[2:].strip() for line in lines if line.strip().startswith('> ')), None)
            if not current_jf:
                results.errors.append(f'could not enumerate JF {label}')
                break
            jf_options.add(current_jf.split()[0])
            terminals.key('jf', 'Down')
            deadline = time.monotonic() + 1
            while time.monotonic() < deadline:
                lines = terminals.capture('jf', False).splitlines()
                after = next((line.strip()[2:].strip() for line in lines if line.strip().startswith('> ')), None)
                if after != current_jf: break
                time.sleep(.05)
            if after == current_jf: break
        else:
            results.errors.append(f'{label}: JF options did not end')
        terminals.key('jf', 'Home')
        terminals.settle(.2)
    seen = set()
    for _ in range(maximum):
        name, index, total = current
        if index in seen: break
        seen.add(index)
        model = name.lstrip('✓ ').split()[0]
        missing = None if jf_open and model in jf_options else f'missing in JF: {label} / {name}'
        results.add(f'{label} / {index:03d} {name}', terminals, missing=missing)
        if len(seen) >= total: break
        terminals.key('pi', 'Down')
        if jf_open: terminals.key('jf', 'Down')
        terminals.settle(.12)
        current = selected(terminals.capture('pi', False))
        if not current: break
    if len(seen) != total:
        results.errors.append(f'{label}: enumerated {len(seen)} of {total} Pi options')



def walk_settings(terminals, results):
    initial = setting(terminals.capture('pi', False))
    if not initial:
        results.errors.append('could not enumerate Pi settings')
        return
    jf_open = 'Auto-compact' in terminals.capture('jf', False)
    visited = set()
    total = initial[3]
    for _ in range(total):
        current = setting(terminals.capture('pi', False))
        if not current or current[2] in visited:
            break
        label, original, index, _ = current
        visited.add(index)
        missing = None if jf_open else 'missing in JF: settings / ' + label
        results.add(f'settings / {index:03d} {label} = {original}', terminals, missing=missing)
        terminals.key('pi', 'Enter')
        if jf_open: terminals.key('jf', 'Enter')
        terminals.settle(.14)
        value = setting(terminals.capture('pi', False))
        if value and value[0] == label and value[2] == index:
            seen = {original}
            while value[1] not in seen and len(seen) < 64:
                seen.add(value[1])
                results.add(f'settings / {label} = {value[1]}', terminals, missing=missing)
                terminals.key('pi', 'Enter')
                if jf_open: terminals.key('jf', 'Enter')
                terminals.settle(.14)
                value = setting(terminals.capture('pi', False))
                if not value or value[0] != label: break
            if not value or value[0] != label or value[1] != original:
                results.errors.append(f'settings / {label}: could not restore initial value')
                return
        else:
            results.add(f'settings / {label} submenu', terminals, missing=missing)
            seen = set()
            for _ in range(100):
                item = choice(terminals.capture('pi', False))
                if not item or item in seen: break
                seen.add(item)
                results.add(f'settings / {label} / {item}', terminals, missing=missing)
                terminals.key('pi', 'Down')
                if jf_open: terminals.key('jf', 'Down')
                terminals.settle(.12)
            if len(seen) == 100:
                results.errors.append(f'settings / {label}: submenu did not wrap')
            terminals.key('pi', 'Escape')
            if jf_open: terminals.key('jf', 'Escape')
            terminals.settle(.2)
        terminals.key('pi', 'Down')
        if jf_open: terminals.key('jf', 'Down')
        terminals.settle(.12)
    if len(visited) != total:
        results.errors.append(f'settings: enumerated {len(visited)} of {total} Pi options')


def walk_choices(terminals, results, label, marker, maximum=200):
    pi_screen = terminals.capture('pi', False)
    total_match = COUNT.search(pi_screen)
    total = int(total_match.group(2)) if total_match else None
    jf_open = marker in terminals.capture('jf', False)
    seen = set()
    for _ in range(maximum):
        value = choice(terminals.capture('pi', False))
        if not value or value in seen: break
        seen.add(value)
        missing = None if jf_open else f'missing in JF: {label} / {value}'
        results.add(f'{label} / {value}', terminals, missing=missing)
        terminals.key('pi', 'Down')
        if jf_open: terminals.key('jf', 'Down')
        terminals.settle(.12)
    if total is not None and len(seen) != total:
        results.errors.append(f'{label}: enumerated {len(seen)} of {total} Pi options')
    if len(seen) == maximum:
        results.errors.append(f'{label}: Pi options did not end or wrap')


def walk_login(terminals, results):
    parent = 'Select authentication method'
    jf_open = parent in terminals.capture('jf', False)
    for target in ('Sign in with an account', 'Sign in with an API key'):
        found = False
        for direction in ('Down', 'Up'):
            for _ in range(10):
                if (choice(terminals.capture('pi', False)) or '').startswith(target):
                    found = True
                    break
                terminals.key('pi', direction)
                if jf_open: terminals.key('jf', direction)
                terminals.settle(.1)
            if found: break
        if not found:
            results.errors.append(f'/login: could not select {target}')
            return
        terminals.key('pi', 'Enter')
        if jf_open: terminals.key('jf', 'Enter')
        terminals.settle(.4)
        marker = 'Select provider to configure'
        results.add('/login / ' + target, terminals, required=marker)
        if marker in terminals.capture('pi', False):
            walk_choices(terminals, results, '/login / ' + target, marker)
        terminals.key('pi', 'Escape')
        if jf_open: terminals.key('jf', 'Escape')
        terminals.settle(.3)


def response_trial(terminals, results, attempt, measure):
    prompt = f'latency-{attempt}'
    marker = f'fixture-{attempt}-first'
    for name in ('pi', 'jf'): terminals.type(name, prompt)
    before = terminals.compilation()
    sent = {}
    for name in ('pi', 'jf'):
        sent[name] = time.monotonic()
        terminals.key(name, 'Enter')
    pending = {'pi', 'jf'}
    timings = {}
    after = None
    deadline = time.monotonic() + 90
    while pending and time.monotonic() < deadline:
        for name in tuple(pending):
            screen = terminals.capture(name, False)
            if marker in screen:
                timings[name] = {'first_response_seconds': time.monotonic() - sent[name], 'first_response_stage': 'complete' if marker + '-complete' in screen else 'partial'}
                if name == 'jf': after = terminals.compilation()
                pending.remove(name)
        if pending: terminals.settle(.01)
    if pending: raise RuntimeError('first response timed out: ' + ', '.join(sorted(pending)))
    valid = measure and compilation_free(before, after)
    if valid: results.add('first response', terminals, required=marker)
    for name in ('pi', 'jf'):
        wait_text(terminals, name, marker + '-complete', timeout=20)
    terminals.settle(.3)
    if valid:
        results.add('first response complete', terminals, required=marker + '-complete')
        results.timings.update(timings)
        results.timings['jf']['compilation_ns'] = 0
        results.timings['warmup_requests'] = attempt
    terminals.editor_ready()
    return valid


def new_session(terminals):
    terminals.send('/new')
    terminals.settle(.4)
    terminals.editor_ready()


def stream_response(terminals, results):
    new_session(terminals)
    marker = 'fixture-check-first'
    terminals.server.stream_gate.clear()
    try:
        for name in ('pi', 'jf'): terminals.type(name, 'stream-check')
        for name in ('pi', 'jf'): terminals.key(name, 'Enter')
        pending = {'pi', 'jf'}
        deadline = time.monotonic() + 1.5
        while pending and time.monotonic() < deadline:
            pending = {name for name in pending if marker not in terminals.capture(name, False)}
            if pending: terminals.settle(.05)
        results.add('streamed response while paused', terminals, required=marker)
    finally:
        terminals.server.stream_gate.set()
    for name in ('pi', 'jf'): wait_text(terminals, name, marker + '-complete', timeout=20)
    terminals.settle(.3)
    results.add('streamed response complete', terminals, required=marker + '-complete')
    terminals.editor_ready()


def first_response(terminals, results):
    for _ in range(3): terminals.compilation()
    found = False
    for attempt in range(10):
        if attempt: new_session(terminals)
        if response_trial(terminals, results, attempt, measure=attempt > 0):
            found = True
            break
        print(f'Warming response path ({attempt + 1} requests)', flush=True)
    if not found: results.errors.append('could not obtain a response timing without Julia compilation')
    stream_response(terminals, results)


def exercise(terminals, results):
    terminals.launch('pi')
    terminals.launch('jf')
    terminals.ready()
    results.timings = terminals.timings
    terminals.settle(.3)
    results.add('startup 100x30', terminals)
    for width, height in ((80, 24), (40, 12), (100, 30)):
        for name in ('pi', 'jf'):
            terminals.tmux('resize-window', '-t', name, '-x', str(width), '-y', str(height))
        terminals.settle(.3)
        results.add(f'viewport {width}x{height}', terminals)
    first_response(terminals, results)
    for name in ('pi', 'jf'): terminals.type(name, 'draft α界 **bold**')
    terminals.settle()
    results.add('editor Unicode and text', terminals)
    terminals.both('Left', 'Left')
    terminals.settle()
    results.add('editor cursor movement', terminals)
    terminals.both('C-e', 'C-u')
    terminals.settle()
    commands = json.loads(subprocess.check_output(['node', str(terminals.project / 'test/interactive_commands.mjs'), str(terminals.source)], text=True))
    for command in commands:
        name = command['name']
        for target in ('pi', 'jf'): terminals.type(target, '/' + name)
        terminals.settle(.15)
        pi = terminals.capture('pi', False)
        jf = terminals.capture('jf', False)
        missing = f'missing Pi command in JF completion: /{name}' if completion_present(pi, name) and not completion_present(jf, name) else None
        results.add('command completion /' + name, terminals, missing=missing)
        terminals.both('C-e', 'C-u')
        terminals.settle(.1)
    terminals.send('/model')
    try:
        wait_text(terminals, 'jf', 'Select model', timeout=15)
    except RuntimeError:
        pass
    terminals.settle(.3)
    missing = None if 'Select model' in terminals.capture('jf', False) else 'missing in JF: model selector'
    results.add('model selector', terminals, missing=missing)
    walk_menu(terminals, results, 'model selector', 'Select model')
    for query in ('gpt-4', '-no-such-model'):
        terminals.tmux('send-keys', '-t', 'pi', '-l', '--', query)
        if not missing: terminals.tmux('send-keys', '-t', 'jf', '-l', '--', query)
        terminals.settle(.4)
        results.add('model selector / search ' + query, terminals, missing=missing)
    terminals.reset()
    terminals.send('/settings')
    terminals.settle(.5)
    results.add('settings menu', terminals, required='Auto-compact')
    walk_settings(terminals, results)
    terminals.tmux('send-keys', '-t', 'pi', '-l', '--', 'autocomplete')
    if 'Auto-compact' in terminals.capture('jf', False): terminals.tmux('send-keys', '-t', 'jf', '-l', '--', 'autocomplete')
    terminals.settle(.4)
    results.add('settings / search autocomplete', terminals)
    terminals.reset()
    for command, expected in (('/thinking', 'Thinking Level'), ('/scoped-models', 'Model Configuration'), ('/login', 'Select authentication method'), ('/trust', 'Project trust'), ('/logout', None), ('/hotkeys', None), ('/session', None), ('/changelog', None), ('/import', None), ('/name', None)):
        terminals.send(command)
        terminals.settle(.5)
        results.add(command + ' screen', terminals, required=expected)
        if expected and expected in terminals.capture('pi', False):
            walk_choices(terminals, results, command, expected)
            if command == '/login': walk_login(terminals, results)
            if command == '/scoped-models':
                terminals.key('pi', 'Enter')
                if expected in terminals.capture('jf', False): terminals.key('jf', 'Enter')
                terminals.settle(.3)
                results.add('/scoped-models / toggle model', terminals)
                terminals.key('pi', 'Enter')
                if expected in terminals.capture('jf', False): terminals.key('jf', 'Enter')
                terminals.settle(.3)
        terminals.reset()
    for command in ('/tree', '/fork', '/resume'):
        terminals.send(command)
        terminals.settle(.5)
        results.add(command + ' screen', terminals)
        terminals.reset()


def browser_path():
    explicit = os.environ.get('JF_UI_CHROMIUM')
    if explicit: return explicit
    for name in ('chromium', 'chromium-browser', 'chrome-headless-shell'):
        path = shutil.which(name)
        if path: return path
    caches = [Path.home() / 'Library/Caches/ms-playwright', Path.home() / '.cache/ms-playwright']
    if os.environ.get('PLAYWRIGHT_BROWSERS_PATH'):
        caches.insert(0, Path(os.environ['PLAYWRIGHT_BROWSERS_PATH']))
    patterns = ('chromium_headless_shell-*/chrome-headless-shell-mac-*/chrome-headless-shell', 'chromium_headless_shell-*/chrome-linux*/headless_shell', 'chromium_headless_shell-*/chrome-linux*/chrome-headless-shell')
    for cache in caches:
        for pattern in patterns:
            candidates = sorted(cache.glob(pattern), reverse=True)
            if candidates: return str(candidates[0])
    return None


def screenshots(results, browser):
    if not browser:
        results.errors.append('isolated Chromium is required to produce terminal screenshots; set JF_UI_CHROMIUM')
        return
    def render(case):
        with tempfile.TemporaryDirectory(prefix='jf-ui-chromium-') as profile:
            env = {key: os.environ[key] for key in ('PATH', 'LANG', 'TMPDIR') if key in os.environ}
            env.update(HOME=profile, XDG_CONFIG_HOME=profile, XDG_CACHE_HOME=profile)
            target = results.output / case['image']
            url = (results.output / case['page']).as_uri()
            command = [browser, '--headless', '--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage', '--disable-extensions', '--disable-background-networking', '--no-first-run', '--no-default-browser-check', '--hide-scrollbars', f'--user-data-dir={profile}', '--window-size=1900,800', f'--screenshot={target}', url]
            try:
                completed = subprocess.run(command, env=env, capture_output=True, text=True, timeout=40)
                if completed.returncode or not target.is_file():
                    return f'screenshot failed for {case["name"]}: {completed.stderr[-500:]}'
            except (OSError, subprocess.TimeoutExpired) as error:
                return f'screenshot failed for {case["name"]}: {error}'
        return None
    with ThreadPoolExecutor(max_workers=3) as pool:
        for index, error in enumerate(pool.map(render, results.cases), 1):
            if error: results.errors.append(error)
            if index % 25 == 0: print(f'Rendered {index} terminal screenshots', flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--project', type=Path, required=True)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--julia', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--no-screenshots', action='store_true')
    parser.add_argument('--font', default='Menlo, Consolas, DejaVu Sans Mono, monospace')
    args = parser.parse_args()
    results = Results(args.output, args.font)
    try:
        revision = subprocess.check_output(['git', '-C', str(args.source), 'rev-parse', 'HEAD'], text=True).strip()
        if revision != 'e7a0df27c09d11bf4161d3605246cbf57a129cb2':
            raise RuntimeError(f'Pi reference is at {revision}, not the pinned revision')
        changes = subprocess.check_output(['git', '-C', str(args.source), 'status', '--porcelain', '--untracked-files=no'], text=True).strip()
        if changes:
            raise RuntimeError('Pi reference has tracked changes; use an unmodified pinned checkout')
        # tmux uses a Unix-domain socket whose path has a small platform limit.
        with tempfile.TemporaryDirectory(prefix='jfui-', dir='/tmp') as directory:
            terminals = Terminals(args.project.resolve(), args.source.resolve(), args.julia, directory)
            try:
                exercise(terminals, results)
            finally:
                terminals.close()
    except Exception as error:
        results.errors.append(str(error))
    results.finish()
    if not args.no_screenshots: screenshots(results, browser_path())
    results.finish()
    for error in results.errors:
        print('ERROR:', error, file=sys.stderr)
    for case in results.cases:
        if not case['match']:
            print('FAIL:', case['name'], ':', '; '.join(case['differences']), file=sys.stderr)
    print(f"Captured {len(results.cases)} states; {sum(not case['match'] for case in results.cases)} differ. Report: {results.output / 'index.html'}", flush=True)
    return int(bool(results.errors) or any(not case['match'] for case in results.cases))


if __name__ == '__main__':
    sys.exit(main())
