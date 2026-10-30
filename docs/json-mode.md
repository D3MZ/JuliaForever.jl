# JSON mode

`jf --mode json 'prompt'` writes one JSON object per line to stdout and exits. The first record is a session header. Each prompt then produces `agent_start`, `turn_start`, message and tool events, `turn_end`, `agent_end`, and `agent_settled`. `message_update` contains a delta and cumulative usage rather than a growing message snapshot. Text, thinking, tool-call arguments, tool output and image content are represented as blocks. Event output is flushed as it arrives. Program and plugin output goes to stderr so stdout remains JSONL.

Piped stdin is trimmed and prepended to the first positional message, and additional positional messages become separate turns. `@PATH` arguments contribute file text or images to the initial turn. With no prompt or piped input, JSON mode emits the header and exits. Tool selection, native plugins and SQLite session options apply in this mode.

A completed, failed, aborted or truncated model response is reported through the assistant message's `stopReason`; these responses do not by themselves produce a nonzero exit status. A startup, history or request exception can still fail the command. As in Pi, clients should examine the event stream to determine the response outcome.

The header ID is the Julia Forever session ID for automatically named sessions. For an explicit SQLite path it is derived from the path; ephemeral sessions get a new ID. The header timestamp is generated when the command starts, including when reopening a session, because existing SQLite histories do not store a creation timestamp. Session files are Julia Forever SQLite histories, not Pi JSONL sessions.

Provider-reported usage is included when available; otherwise it is zero. When a provider reports only a total cost, the component costs are zero. Tool events currently omit execution duration. Provider block boundaries, thinking signatures, retry and compaction events, and exception recovery are not fully equivalent to Pi. `--mode rpc` is not implemented. The tests compare text and tool-event ordering with the pinned Pi agent loop and exercise a local streaming provider; they do not prove complete protocol parity or behavior on every platform.
