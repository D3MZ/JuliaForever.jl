# Automatic compaction threshold

`JuliaForever.autocompact!(agent, usage, JuliaForever.AutoCompaction(context_window, reserve_tokens; enabled=true))` checks provider usage at a safe turn boundary and invokes the existing compactor above the reserve threshold. It returns `nothing` when no check is possible or the threshold is not crossed; otherwise it returns the compactor's result. A fourth argument can supply a summarizer for testing or customization.

This is a caller-driven building block, not yet wired into `respond!` or the terminal. The caller must pass usage from the current, projected, post-compaction response at an idle boundary. It does not estimate missing or zero usage, detect overflow or recoverable length, retry a turn, handle model changes or context edits, or implement Pi's lifecycle hooks. Those require session-level integration. A failed compaction is returned to the caller.
