# Julia Forever

An experimental native Julia agent harness, working toward compatibility with [Pi](https://github.com/earendil-works/pi). The current target is Pi revision `e7a0df27c09d11bf4161d3605246cbf57a129cb2`.

The current prototype supports OpenAI-compatible chat completions for OpenAI and OpenRouter, streamed text and function calls through its Julia API, text `read`, `write`, `edit`, shell and directory-listing tools, and an independent durable-storage foundation. Pi sessions, plugin conversion, Julia code mode, MCP, terminal UI, and other tools remain unimplemented. Text editing currently supports exact matches only. See [provider setup](docs/providers.md), [shell limitations](docs/system-tools.md), and [durable storage](docs/durable.md).

## Run from a checkout

Julia 1.12 or newer runs the package and its native tests. Node.js is needed only for differential tests that run the original Pi implementation. Set `OPENAI_API_KEY` and `OPENAI_MODEL`, and optionally `OPENAI_BASE_URL` (default `https://api.openai.com/v1`).

```sh
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. -m JuliaForever 'Create a hello.txt file'
```

To install the `jf` command from the checkout, run `julia -e 'using Pkg; Pkg.Apps.add(path=pwd())'` and put the Julia depot's `bin` directory on your `PATH`. Julia's app support is experimental. Run `jf` without a prompt for a simple line-oriented session; `/exit` ends it.

## Test

```sh
julia --project=. -e 'using Pkg; Pkg.test()'
```

Set `PI_SOURCE` to a checkout of the pinned Pi revision with its Node dependencies available to also run the differential file-tool and provider cases. The CI workflow prepares that reference on macOS, Linux, and Windows. Until a particular run passes, a configured CI job is not evidence of platform compatibility. Test results cover selected cases, not full Pi compatibility.

Pi is MIT-licensed; its copyright and license notice is included in `third_party/pi-LICENSE`.
