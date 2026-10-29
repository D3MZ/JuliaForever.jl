# Julia Forever

An experimental native Julia agent harness, working toward compatibility with [Pi](https://github.com/earendil-works/pi). The current target is Pi revision `e7a0df27c09d11bf4161d3605246cbf57a129cb2`.

The current prototype supports a nonstreaming OpenAI-compatible chat completions endpoint and basic text `read`, `write`, and `edit` tools. It is not yet a Pi replacement: streaming, Pi sessions, extensions and automatic plugin conversion, Julia code mode, MCP, terminal UI, and most tools are unimplemented. Text editing currently supports exact matches only.

## Run from a checkout

Julia 1.12 or newer and Node.js are needed for the full test suite; the runtime itself uses Julia. Set `OPENAI_API_KEY` and `OPENAI_MODEL`, and optionally `OPENAI_BASE_URL` (default `https://api.openai.com/v1`).

```sh
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. -m JuliaForever 'Create a hello.txt file'
```

Run without a prompt for a simple line-oriented session; `/exit` ends it. The declared Julia app name is `jf`.

## Test

```sh
julia --project=. -e 'using Pkg; Pkg.test()'
```

Set `PI_SOURCE` to a checkout of the pinned Pi revision with its Node dependencies available to also run the differential file-tool cases. The CI workflow prepares that reference on macOS, Linux, and Windows. Until a particular run passes, a configured CI job is not evidence of platform compatibility. Test results cover selected cases, not full Pi compatibility.

Pi is MIT-licensed; its copyright and license notice is included in `third_party/pi-LICENSE`.
