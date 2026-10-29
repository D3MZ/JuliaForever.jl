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

The last expression is the result. Programs may define Julia types, methods, and multiple-dispatch functions. `text(value)` records a text item; non-strings are encoded as JSON. Normal stdout and stderr are captured separately. Values and tool arguments must be JSON-serializable. `ALL_TOOLS` lists tool names, descriptions, and argument schemas; the model-facing tool description includes them too. Both `tools.read((; path="..."))` and `tools["read"]((; path="..."))` invoke a registered tool. Each call returns an object with `text` and `iserror`, including failures and unknown tool names. Calls can run concurrently using Julia tasks; a separate host task runs each registered tool.

`codeexecute(mode, source; store, cancel)` returns a `CodeResult` with `ok`, `value`, `output`, `calls`, `writes`, `kind`, `message`, `stdout`, `stderr`, and worker `pid`. Failure kinds are `:script`, `:worker`, `:timeout`, and `:cancelled`. Call statuses are `:ok`, `:error`, and `:unresolved`; the host did not observe an unresolved call finish before the result was returned. The captured output is kept on failure. `store(key, value)` and `load(key)` operate on JSON values supplied in the caller's `store` dictionary. Successful `codeexecute` runs return changed keys in `writes`; the caller decides whether to apply them. The tool interface `execute(mode, args)` keeps successful writes in that `CodeMode` instance for subsequent calls. Concurrent executions each use a snapshot and the last completed write to a key wins. Failed runs return no writes. Missing keys load as `nothing`. Deleting keys is not implemented.

The deadline begins when execution starts and includes tool calls. `CodeCancellation()` and `cancel!(token)` request cancellation. When a run ends, times out, or is cancelled, the host terminates and waits for the Julia worker process. It does **not** terminate subprocesses created by the program or forcibly cancel host tools already in progress. Those tools can still make changes after the result is returned. A non-yielding host tool can also delay deadline and cancellation handling, especially in a single-threaded host. Use cooperative cancellation and operating-system isolation if those guarantees are required.

This is a foundation, not Pi code-mode compatibility: images, Pi's VM restrictions, store deletion, output limits, durable replay, and plugin conversion are not implemented. It has been exercised on the development platform only; cross-platform behavior remains unverified.
