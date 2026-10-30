# Shell and directory tools

Tool execution returns `ToolSuccess` or `ToolFailure`, both subtypes of `ToolResult`. Each has `text`; the `iserror` property and `ToolResult(text, iserror)` constructor remain available for protocol compatibility.

At the agent boundary, unknown tool names, invalid call envelopes or JSON, and operating-system errors become tool failures; other exceptions interrupt the turn with their original type and stack. Direct calls to `execute` retain their existing exception behavior.

`Bash`, `PowerShell`, and `Ls` use Julia and the host shell; Pi and Node are used only by optional differential tests. The command runner captures combined stdout and stderr, returns nonzero exit status as an error, stores truncated output in a temporary file, and exposes the last 2,000 lines or 50 KiB. `PowerShell` is available only on Windows, matching Pi's platform boundary.

Direct shell calls accept `on_update`, which receives cumulative `ShellUpdate` snapshots while the command runs. Truncated updates include the retained full-output file path. Agent and terminal event wiring remains separate work.

On Unix, a shell can be cancelled from another Julia task:

```julia
cancel = ShellCancellation()
task = @async execute(Bash(pwd()), (; command="sleep 30"); cancel)
cancel!(cancel)
result = fetch(task) # ToolResult with an error and "Command aborted"
```

A token can be shared by concurrent shell calls. Cancellation is idempotent and permanent: a call that has not started when its token is cancelled does not start. Create a new token for later calls. A timeout or cancellation sends `SIGKILL` to the shell's process group and waits for the shell. The outcome is chosen once: completion wins if the shell has already been observed to exit; otherwise the first timeout or cancellation signal wins. If signalling fails, the result reports that the command may still be running. Timeouts and cancellation use Julia timers and tasks, so scheduling delays can postpone handling.

The process-group signal covers members that remain in the original group, including ordinary children and grandchildren. The runner does not wait for or reap those descendants; they may take time to disappear after the shell exits. Processes that change their process group or session, survive because of permissions or an uninterruptible kernel operation, or outlive a normally completed shell are outside this cleanup guarantee. Effects already performed are not undone. Successful commands that leave background descendants running may continue writing to the output file after the shell exits.

On Windows, passing a cancellation token or a timeout returns an explicit unsupported result before starting the command; untimed commands without a token retain their existing behavior. For an in-process `Agent`, `cancel!(agent)` stops active Unix shell calls, including parallel calls, and prevents later calls from starting. It does not interrupt a running provider, other tools, Windows shell calls, or tools run through the separate executor-backed path. Recorded agents use the same in-process shell cancellation after the cancellation transition is persisted. See [native execution](execution.md) for executor cancellation.

The tested Pi cases cover ordinary output, errors, Unix timeout and cancellation, output truncation, and selected streaming updates. The implementation does not yet provide agent or terminal streaming updates, Pi's structured shell output, custom shells, shell hooks, session metadata, or Windows WSL shell transport. Directory sorting uses Julia's case-insensitive lexical order, which can differ from Pi's locale-aware collation. Advanced file-tool parity and cross-platform verification remain outstanding. Native search and its remaining differences are described in [search-tools.md](search-tools.md).

Safe group signalling uses Julia's internal process-handle and I/O lock APIs to prevent PID reuse while signalling. The current tests were run with Julia 1.12.6 on macOS. Compatibility with other Julia versions must be verified; the conditional Windows cases are not evidence of a Windows test run.

Pi may report an abort if its signal is set after the child exits but before its exit handler settles. This runner preserves a shell completion once the exit has been observed.
