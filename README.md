# Julia Forever

An experimental native Julia agent harness. B1 surface-parity tests use [Pi](https://github.com/earendil-works/pi) revision `e7a0df27c09d11bf4161d3605246cbf57a129cb2` as a reference.

The [B1 specification](docs/b1.md), [surface evidence map](docs/b1-surface.md), and [architecture](docs/architecture.md) describe the native Julia design and Pi's role as a differential reference.

The current prototype supports OpenAI Responses and OpenAI-compatible chat completions for OpenAI and OpenRouter, streamed text and function calls, typed agent transitions and replay, text and bounded PNG/JPEG `read`, `write`, `edit`, shell, directory-listing and native search tools, project instructions, JSON and HTML history export, opt-in Julia code mode, and an MCP stdio tool adapter. An agent can record transitions to memory, a Unix JSONL store, or SQLite and reopen them. The terminal can resume a SQLite history with `--history PATH`. An opt-in executor can run sequential, non-streaming agent effects on configured Julia processes, including with recorded history. Native Julia packages can provide custom tools and lifecycle observers to the CLI when explicitly selected; automatic discovery, MCP HTTP/OAuth, a full-screen terminal UI, and other features remain unimplemented. See [project instructions](docs/instructions.md), [file editing](docs/file-editing.md), [terminal](docs/terminal.md), [providers](docs/providers.md), [shell](docs/system-tools.md), [search](docs/search-tools.md), [transitions](docs/conversation.md), [execution](docs/execution.md), [durable storage](docs/durable.md), [tasks](docs/scheduler.md), [sessions](docs/sessions.md), [histories](docs/history.md), [history export](docs/logs.md), [MCP stdio](docs/mcp.md), [extensions](docs/extensions.md), and [code mode](docs/codemode.md) for limitations.

## Run from a checkout

Julia 1.12 or newer runs the package and its native tests. Node.js is needed only for differential tests that run the original Pi implementation. Set `OPENAI_API_KEY` and `OPENAI_MODEL`, and optionally `OPENAI_BASE_URL` (default `https://api.openai.com/v1`). Set `JF_PROVIDER=openai-responses` to use the Responses API.

```sh
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. -m JuliaForever 'Create a hello.txt file'
```

To install the `jf` command from the checkout, run `julia -e 'using Pkg; Pkg.Apps.add(path=pwd())'` and put the Julia depot's `bin` directory on your `PATH`. Julia's app support is experimental. Run `jf` without a prompt for a session; `/exit` ends it. On a supported terminal, Enter sends and Ctrl+J inserts a line. See [terminal](docs/terminal.md) for input and platform limitations.

Pass `--history session.sqlite` to record and resume the same conversation in later invocations. Persistence is opt-in; SQLite.jl is installed as a package dependency. See [terminal recovery](docs/terminal.md) before continuing an interrupted turn.

## Test

```sh
PI_SOURCE=/path/to/pi julia --startup-file=no --threads=4 --project=. scripts/ci.jl
```

This runs the native quality and behavior tests plus selected Pi comparisons locally. On Unix with Git and Python 3.11 or newer it also installs a snapshot of the current source into a temporary depot, offline, and tests the installed CLI with a native plugin. `PI_SOURCE` must point to the pinned Pi checkout with its Node dependencies available. Pass `--native-only` instead to run without Pi; that mode explicitly skips differential tests. The GitHub workflow also prepares the reference and tests macOS. Linux and Windows testing will follow. Until a particular run passes, a configured CI job is not evidence of platform compatibility. Test results cover selected cases, not full Pi compatibility.
