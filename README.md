# Julia Forever

An experimental native Julia agent harness. B1 surface-parity tests use [Pi](https://github.com/earendil-works/pi) revision `e7a0df27c09d11bf4161d3605246cbf57a129cb2` as a reference.

The [B1 specification](docs/b1.md), [surface evidence map](docs/b1-surface.md), and [architecture](docs/architecture.md) describe the native Julia design and Pi's role as a differential reference.

The current prototype supports OpenAI Responses, OpenAI-compatible chat completions for OpenAI and OpenRouter, Anthropic Messages, and Google Generative AI. It provides streamed text and function calls, typed agent transitions and replay, text `read`, `write`, `edit`, shell, directory-listing and native search tools, project instructions, JSON and HTML history export, opt-in Julia code mode, and an MCP stdio tool adapter. An agent can record transitions to memory, a Unix JSONL store, or SQLite and reopen them. The terminal saves sessions automatically and can continue, select, and branch them. An opt-in executor can run sequential, non-streaming agent effects on configured Julia processes, including with recorded history. Native Julia plugins, MCP HTTP/OAuth, a full-screen terminal UI, and other features remain unimplemented. See [project instructions](docs/instructions.md), [file editing](docs/file-editing.md), [terminal](docs/terminal.md), [providers](docs/providers.md), [shell](docs/system-tools.md), [search](docs/search-tools.md), [transitions](docs/conversation.md), [execution](docs/execution.md), [durable storage](docs/durable.md), [tasks](docs/scheduler.md), [sessions](docs/sessions.md), [histories](docs/history.md), [history export](docs/logs.md), [MCP stdio](docs/mcp.md), and [code mode](docs/codemode.md) for limitations.

## Run from a checkout

Julia 1.12 or newer runs the package and its native tests. Node.js is needed only for differential tests that run the original Pi implementation. Set `OPENAI_API_KEY` and `OPENAI_MODEL`, and optionally `OPENAI_BASE_URL` (default `https://api.openai.com/v1`). Set `JF_PROVIDER=openai-responses` to use the Responses API. Set `JF_PROVIDER=anthropic` with `ANTHROPIC_API_KEY` and `ANTHROPIC_MODEL`, or `JF_PROVIDER=google` with `GEMINI_API_KEY` and `GEMINI_MODEL`, for those APIs.

```sh
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. -m JuliaForever 'Create a hello.txt file'
```

To install the `jf` command from the checkout, run `julia -e 'using Pkg; Pkg.Apps.add(path=pwd())'` and put the Julia depot's `bin` directory on your `PATH`. Julia's app support is experimental. Run `jf` without a prompt for an interactive session: Enter sends, Ctrl+J adds a line, and `/exit` ends it. During a request, Enter steers, Alt+Enter queues a follow-up, and Escape interrupts.

Sessions are saved automatically. Use `jf --continue` for the most recent session, `jf --resume` to choose one, or `jf --session PATH|ID` to open a specific session. In the terminal, `/resume` switches sessions and `/tree` selects an earlier message while retaining the other branches. `--no-session` starts an ephemeral session. `--history session.sqlite` still records and resumes an explicitly chosen history file. See [terminal recovery](docs/terminal.md) before continuing an interrupted turn.

## Test

```sh
julia --project=. -e 'using Pkg; Pkg.test()'
```

Set `PI_SOURCE` to a checkout of the pinned Pi revision with its Node dependencies available to also run differential agent, tool and provider cases. The CI workflow prepares that reference on macOS, Linux, and Windows. Until a particular run passes, a configured CI job is not evidence of platform compatibility. Test results cover selected cases, not full Pi compatibility.
