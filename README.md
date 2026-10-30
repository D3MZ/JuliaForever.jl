# Julia Forever

An experimental native Julia agent harness. B1 surface-parity tests use [Pi](https://github.com/earendil-works/pi) revision `e7a0df27c09d11bf4161d3605246cbf57a129cb2` as a reference.

The [B1 specification](docs/b1.md), [surface evidence map](docs/b1-surface.md), and [architecture](docs/architecture.md) describe the native Julia design and Pi's role as a differential reference.

The current prototype supports OpenAI Responses, OpenAI-compatible chat completions for OpenAI and OpenRouter, Anthropic Messages, and Google Generative AI, with streamed text and function calls, typed agent transitions and replay, text and bounded PNG/JPEG `read`, `write`, `edit`, shell, directory-listing and native search tools, project instructions, JSON and HTML history export, opt-in Julia code mode, and MCP stdio tools and resources. An agent can record transitions to memory, a Unix JSONL store, or SQLite and reopen them. The terminal saves SQLite sessions, can continue, select, and branch them, and accepts text and image files as `@PATH` arguments. An opt-in executor can run sequential, non-streaming agent effects on configured Julia processes, including with recorded history. Native Julia packages can provide custom tools and lifecycle observers to the CLI when explicitly selected; automatic discovery, MCP OAuth, a full-screen terminal UI, and other features remain unimplemented. See [project instructions](docs/instructions.md), [file editing](docs/file-editing.md), [terminal](docs/terminal.md), [providers](docs/providers.md), [shell](docs/system-tools.md), [search](docs/search-tools.md), [transitions](docs/conversation.md), [execution](docs/execution.md), [durable storage](docs/durable.md), [tasks](docs/scheduler.md), [sessions](docs/sessions.md), [histories](docs/history.md), [history export](docs/logs.md), [MCP stdio](docs/mcp.md), [extensions](docs/extensions.md), and [code mode](docs/codemode.md) for limitations.

An opt-in [context estimate](docs/context-estimates.md) combines a caller-selected provider usage measurement with approximate message sizes; it is not an exact tokenizer or automatic context management.

## Run from a checkout

Julia 1.12 or newer runs the package and its native tests. Node.js is needed only for differential tests that run the original Pi implementation. Set `OPENAI_API_KEY` and `OPENAI_MODEL`, and optionally `OPENAI_BASE_URL` (default `https://api.openai.com/v1`). Set `JF_PROVIDER=openai-responses` to use the Responses API.

For Anthropic set `JF_PROVIDER=anthropic`, `ANTHROPIC_API_KEY` and `ANTHROPIC_MODEL`; for Google set `JF_PROVIDER=google`, `GEMINI_API_KEY` and `GEMINI_MODEL`.

```sh
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. -m JuliaForever 'Create a hello.txt file'
```

To install the `jf` command from the checkout, run `julia -e 'using Pkg; Pkg.Apps.add(path=pwd())'` and put the Julia depot's `bin` directory on your `PATH`. Julia's app support is experimental. Run `jf` without a prompt for a session; `/exit` ends it. On a supported terminal, Enter sends, Ctrl+J inserts a line, Alt+Enter queues a follow-up, and Escape interrupts an active request. See [terminal](docs/terminal.md) for input and platform limitations.

Use `jf --mode json 'prompt'` to stream structured message and tool events as JSONL; see [JSON mode](docs/json-mode.md).

By default the CLI enables `read`, `bash`, `edit`, and `write`, plus explicitly loaded plugin tools. Use `--tools`, `--exclude-tools`, `--no-builtin-tools`, or `--no-tools` to choose the available tools; see [terminal tools](docs/terminal.md).

Sessions are saved automatically. Use `jf --continue` for the most recent session, `jf --resume` to choose one, `jf --session PATH|ID` to open a specific session, or `jf --fork PATH|ID` to copy one. In the terminal, `/new` starts a session with freshly discovered skills, `/name NAME` names it, `/resume` switches sessions, `/tree` selects an earlier message while retaining other branches, `/fork` creates a session from an earlier message, and `/clone` copies the active branch. `--name NAME` sets the initial name and `--no-session` starts an ephemeral session; `/resume` can then select a saved session. `--history session.sqlite` records and resumes an explicitly chosen history file. Resume from the original project directory with the intended tool and plugin options: the saved context and skill metadata are not regenerated, and explicit paths can open histories from a different project. See [terminal sessions and recovery](docs/terminal.md) for details.

## Test

```sh
PI_SOURCE=/path/to/pi julia --startup-file=no --threads=4 --project=. scripts/ci.jl
```

This runs the native quality and behavior tests plus selected Pi comparisons locally. On Unix with Git and Python 3.11 or newer it also installs a snapshot of the current source into a temporary depot, offline, and tests the installed CLI with a native plugin. `PI_SOURCE` must point to the pinned Pi checkout with its Node dependencies available. Pass `--native-only` instead to run without Pi; that mode explicitly skips differential tests. The GitHub workflow also prepares the reference and tests macOS. Linux and Windows testing will follow. Until a particular run passes, a configured CI job is not evidence of platform compatibility. Test results cover selected cases, not full Pi compatibility.

Automatic usage-backed compaction can be enabled per `respond!` call with
`auto_compaction=JuliaForever.AutoCompaction(context_window, reserve_tokens)`.
It checks the last model usage after a successful run, when the agent is idle,
and retains the completed response. Pass `summarize=callable` to control the
summary; otherwise the agent's provider is used. A compaction result (including
rejection or cancellation) is reported as an `:auto_compaction_end` agent event.
History-backed agents persist the checkpoint for replay. Missing usage, disabled
settings, and cancelled or failed turns do not trigger compaction. This threshold
path does not implement Pi's overflow retry or pre-prompt recovery.

Julia Forever can read literal API keys from Pi's `auth.json` in `PI_CODING_AGENT_DIR` (default `~/.pi/agent`); a stored key takes precedence over the provider's environment variable. Reading does not change the file or its permissions. Malformed or missing files fall back to the environment. Credential commands, environment templates, OAuth credentials and refresh, and writing or removing stored credentials are not supported by this lookup. OpenRouter login remains session-only.
