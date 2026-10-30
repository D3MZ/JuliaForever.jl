# Replaceable histories

`JuliaForever.History` offers an in-memory store, an adapter over `Durable.Store`, and a SQLite store with the same append and snapshot operations.

```julia
using JuliaForever
import JuliaForever.Durable as D
import JuliaForever.History as H

memory = H.Memory()
H.append!(memory, 0, Any[Dict("kind" => "plan"), Dict("kind" => "observation")]) # 1
view = H.snapshot(memory)
collect(view)               # records in order
view.revision               # 1
view.batches                # detached revision batches

store = open(D.Store, "history.jsonl")
history = H.create(store)
id = history.id             # retain this ID to reopen the history
H.append!(history, 0, Any[Dict("kind" => "plan")])
close(store)

store = open(D.Store, "history.jsonl")
history = H.Journal(store, id)
collect(H.snapshot(history))
close(store)
```

Open one SQLite history per database file:

```julia
using SQLite, JuliaForever
import JuliaForever.History as H

history = open(H.SQLite, "history.sqlite")
H.append!(history, 0, Any[Dict("kind" => "plan")])
close(history)

history = open(H.SQLite, "history.sqlite")
view = H.snapshot(history)
close(history)
```

`append!` compares the expected revision and atomically appends a nonempty vector as one revision. Memory, journal, and SQLite history revisions count batches; an application defines how they relate to its state-machine revisions. Success returns the new revision. A stale revision returns `Rejected(:revision)` and an empty batch returns `Rejected(:empty_batch)`; neither changes history. The durable transaction serializes competing appends through the underlying store. A snapshot copies batches and preserves their boundaries, and each iteration returns detached records in order. Later writes and mutations to the input, a returned batch, or a previously iterated record cannot alter the snapshot. It can be passed directly to `Logs.json` and `Logs.html`.

Journal and SQLite snapshots return `Rejected(:history_format)` for malformed stored values, including unknown tags, invalid numeric text, nonfinite floats, and empty batches. Raw malformed records are not included in that result. For compatibility, previously readable raw integers and shorter finite hexadecimal float encodings remain readable; JSON3 normalizes an integral numeric tag such as `0.0` to an integer before decoding.

`H.Tree(history)` wraps a recorded agent history with branches. `H.entries(tree)` returns detached node IDs, parents, and batches for all branches; `H.snapshot(tree)` projects the active path. Its revision is the active leaf ID, rather than the number of projected batches. `H.branch!(tree, id)` selects a node without erasing other paths. Selection is in memory until the next append; reopening selects the most recently appended node. A new append compares both the selected leaf and the underlying store revision, so a stale agent or competing writer is rejected. Branching rejects a current or target path with an incomplete turn or pending effect. Kernel effect IDs are unique within a replayed state, not across branches: alternative paths can reuse an ID. A supervisor using effect IDs as external idempotency keys must add a unique branch or run identifier. The wrapper accepts existing linear agent histories; after a tree append, reopen that history through `H.Tree` to interpret its branch records. Closing a tree over memory or a journal leaves the underlying store open; closing one over SQLite closes the SQLite connection.

Supported records consist recursively of `nothing`, `Bool`, `Int`, finite `Float64`, valid UTF-8 `String`, Julia `Vector`s, and `Dict`s with valid UTF-8 `String` keys. Container element types and object identity are not preserved: arrays are returned as `Vector{Any}` and objects as `Dict{String, Any}`. Cycles, other numeric and string types, tuples, symbols, structs, and other values return `Rejected(:unsupported_value)` for the whole batch. The journal encodes integer values and floating-point bits explicitly to preserve `Int`, `Float64`, and signed zero despite JSON number parsing. The optional agent integration uses a separate versioned codec for the built-in conversation and kernel events; see [conversation transitions](conversation.md). Extension types need an explicit codec and arbitrary Julia objects are not serialized.

The journal stores each history in a durable document under a private format marker; do not modify that document outside this adapter. It retains the ID across close and reopen. It inherits the [durable store](durable.md)'s exclusive single-process file ownership, `fsync` and recovery behavior, failed-store handling, platform support, and limitations. Opening on unsupported platforms, including Windows, returns `D.Rejected(:unsupported_platform)`. History operations on a closed or failed store return `H.Rejected` with the corresponding reason. Each append currently replaces the complete document, so time, memory, and log size grow with history; there is no compaction or performance claim.

SQLite.jl is a JuliaForever dependency. A direct `Agent` opts into history explicitly; the CLI saves SQLite sessions by default. A file is one history, and independent connections and processes can open it at the same time. Each compare-and-append uses a SQLite write transaction, and each snapshot reads a consistent set of complete batches. The connection waits up to five seconds for a database lock; SQLite errors, including lock timeouts, propagate. The adapter requests SQLite's `synchronous=EXTRA` and accepts its persistent rollback-journal and WAL modes. An unrelated database returns `H.Rejected(:history_format)`; `open(H.SQLite, path; create=false)` also rejects a missing or uninitialized file instead of creating a history. The private tables and database settings should not be modified directly. Keep SQLite's sidecar files with the database and use SQLite's backup API for a live database. SQLite's durability depends on the filesystem and storage honoring its locking and sync operations. The implementation was tested on macOS; Windows and Linux have not been validated.

If a SQLite append encounters an exception during its transaction, the exception propagates and that connection rejects later operations with `H.Rejected(:uncertain)`. Close it, reopen the database, and inspect the revision and batches before deciding what to do. SQLite recovers its journal as needed on reopening; a committed transaction may be present even when the caller did not receive its result. Other writers may have continued, so application-level identity and reconciliation can still be necessary. History operations on a closed SQLite connection return `H.Rejected(:closed)`.

After a journal write or sync failure, its batch outcome can likewise be uncertain: close and reopen the store and inspect its revision and batches. Histories only record data: reading and replaying them never dispatches effects, and storing a plan does not establish whether any external effect happened or provide exactly-once execution. The agent can opt into any history; it does not automatically retry or reconcile external work. An interrupted agent with a pending effect returns `H.Rejected(:uncertain_effect)` on resume; after inspecting the external state, call `abandon!(agent, reason)` to record an explicit decision before starting another turn.
