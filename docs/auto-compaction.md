# Automatic compaction threshold

`JuliaForever.autocompact!(agent, usage, JuliaForever.AutoCompaction(context_window, reserve_tokens; enabled=true))` checks provider usage at a safe turn boundary and invokes the existing compactor above the reserve threshold. It returns `nothing` when no check is possible or the threshold is not crossed; otherwise it returns the compactor's result. A fourth argument can supply a summarizer for testing or customization.

The constructor now returns an enabled or disabled `AutoCompaction` subtype. The previous concrete type and its `enabled::Val` field have changed; the `enabled` keyword and threshold fields remain supported.

`respond!` accepts `auto_compaction` and an optional `summarize` callable, and checks the last reported usage after a successful turn. The terminal exposes manual `/compact`; automatic compaction is not configured by the terminal. The executor path uses its last model usage and is subject to the executor limitations in `docs/execution.md`. It does not estimate missing or zero usage, detect overflow or recoverable length, retry a turn, handle model changes or context edits, or implement Pi's compaction lifecycle hooks. Those require session-level integration. A failed compaction is returned to the caller.
