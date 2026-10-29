# Session history

`JuliaForever.Sessions` is a native Julia session-tree foundation. It is independent of `Durable` and is not yet connected to `Agent` or the command line. The CLI separately saves SQLite-backed sessions and provides recent, picker and explicit-path selection; see [terminal](terminal.md). Pi and Node are not runtime dependencies; the v3 JSONL framing is used for the selected interoperability tests and is not a requirement on future native storage.

```julia
using JuliaForever
const S = JuliaForever.Sessions

session = S.Session("history.jsonl"; cwd=pwd())
question = S.record!(session, Dict("role" => "user", "content" => "Hello"))
answer = S.record!(session, Dict("role" => "assistant", "content" => "Hi"))
S.branch!(session, question)
S.record!(session, Dict("role" => "assistant", "content" => "Hello again"))

S.messages(session)             # raw messages on the active path
S.branch(session, answer)       # the original path, including entry metadata
S.children(session, question)  # direct child entries
reopened = open(S.Session, "history.jsonl")
```

`S.Session(; cwd=pwd())` is in-memory; supplying a path enables file persistence. New files are created exclusively on the first user or assistant message, after recording any preceding setup entries. The parent directory must exist. `S.record!(session, type, fields)` appends other JSON-serializable entry types; the manager supplies the type, unique entry ID, parent ID, and timestamp. Inputs and query results are copied. `S.branch!(session, id)` moves the leaf and returns `false` for an unknown ID; `nothing` moves it before all entries. Branch selection alone is in memory. The next append records the selected parent, and reopening selects the last appended entry. Write errors propagate before the entry or leaf is changed in memory.

At the pinned Pi revision, the differential cases compare message and metadata appends, branching and resetting, children and paths, deferred file creation, and reopen behavior. Both implementations read the other's generated file for those cases. These tests establish only that selected subset, not complete Pi file or feature compatibility. Native session IDs are random hexadecimal strings rather than Pi's generated UUIDv7 identifiers. `open` accepts the implemented v3 framing, returns `S.Rejected(:invalid_session)` for invalid or unsupported input, and leaves it unchanged. Unlike Pi, it rejects malformed lines and v1/v2 files instead of skipping or migrating them. It validates the framing and unique IDs, not every entry schema or parent graph.

`messages` returns raw `message` entries; it does not apply compaction, branch summaries, context edits, custom-message projections, or model/thinking-state restoration. Branch summaries, labels, session discovery, session export/forking, auto-compaction, and agent-loop integration remain unimplemented. The format currently has no locking, multi-process coordination, fsync guarantee, crash-tail recovery, or integrity protection; partial failed writes can leave an invalid file that must be inspected or recovered externally. Concurrent writers to one path are unsupported. Windows and Linux behavior has not been verified in this change.
