# Julia code mode

`CodeMode` runs Julia source in a new Julia process for each execution. It is a process boundary, **not a security sandbox**: the program inherits the host's effective permissions and environment, including access to files, network, and subprocesses where those permissions allow it. Only run code you trust. The worker can tamper with its own protocol and output. There are no memory or output limits.

Create a mode from the tools to expose, then call it through the tool interface:

```julia
mode = CodeMode([Read(pwd()), Write(pwd()), Edit(pwd())]; timeout=60)
result = execute(mode, (; code="""
    file = tools.read((; path="README.md"))
    text(file.text)
    file.iserror
    """))
```

Run `jf --codemode` to expose it to the terminal agent. Put `--codemode` before `--login-openrouter` when using both options.

The last expression is the result. Programs may define Julia types, methods, and multiple-dispatch functions. `text(value)` records a text item; non-strings are encoded as JSON. Normal stdout and stderr are captured separately. Values and tool arguments must be JSON-serializable. `ALL_TOOLS` lists tool names, descriptions, and argument schemas; the model-facing tool description includes them too. Both `tools.read((; path="..."))` and `tools["read"]((; path="..."))` invoke a registered tool. Each completed call returns an object with `text` and `iserror`, including expected failures and unknown tool names. An unexpected host tool exception ends code execution with a `:worker` failure and diagnostic stack. If a tool returns an image, CodeMode returns an explicit error because it cannot forward images. Calls can run concurrently using Julia tasks; a separate host task runs each registered tool.

`codeexecute(mode, source; store, cancel)` returns a `CodeSuccess` or `CodeFailure`, both subtypes of `CodeResult`, with `ok`, `value`, `output`, `calls`, `writes`, `deletes`, `kind`, `message`, `stdout`, `stderr`, and worker `pid`. Failure kinds are `:script`, `:worker`, `:timeout`, and `:cancelled`. Call statuses are `:ok`, `:error`, and `:unresolved`; the host did not observe an unresolved call finish before the result was returned. If the worker's tool input closes, pending and subsequent tool calls receive an `iserror` result. The captured output is kept on failure.

`store(key, value)` and `load(key)` operate on JSON values supplied in the caller's `store` dictionary; `forget!(key)` deletes a key, including one absent from the snapshot. `store(key, nothing)` stores JSON null: `load` returns `nothing` for both a stored null and a missing key. Within a run the last operation on each key wins. Successful `codeexecute` runs return changed values in `writes` and deleted keys in `deletes`; callers choose whether to apply them. Deletion order is unspecified. The tool interface `execute(mode, args)` atomically applies both to that `CodeMode` instance for subsequent calls. Concurrent executions each use a snapshot; for a given key, the last applied run wins. Failed runs return no writes or deletions. Unlike Pi's `store(key, undefined)` deletion, Julia uses an explicit mutation helper and keeps `nothing` as a JSON value. These state changes are not persisted to session history.

```julia
state = Dict{String, Any}("cursor" => "old")
result = codeexecute(mode, "forget!(\"cursor\"); store(\"done\", true)"; store=state)
if result.ok
    foreach(key -> delete!(state, key), result.deletes)
    merge!(state, result.writes)
end
```

The deadline begins when execution starts and includes tool calls. `CodeCancellation()` and `cancel!(token)` request cancellation, including for multiple runs sharing a token. Protocol coordination uses bounded channels and Julia tasks, and runs with one or more Julia threads. When a run ends, times out, or is cancelled, the host terminates and waits for the Julia worker process and its own protocol tasks. It does **not** terminate subprocesses created by the program or forcibly cancel host tools already in progress. Those tools can still make changes after the result is returned. A non-yielding host tool can also delay deadline and cancellation handling, especially in a single-threaded host. Use cooperative cancellation and operating-system isolation if those guarantees are required.

This is a foundation, not Pi code-mode compatibility: images, Pi's VM restrictions, output and store-size limits, and durable replay are not implemented. Process pipes, descriptor duplication, and termination have been exercised on macOS with Julia 1.12; Linux and Windows remain unverified.

CLI tool selection controls which tools the `tools` interface exposes inside code mode. Julia code itself retains the user’s permissions; tool selection is not a sandbox.
