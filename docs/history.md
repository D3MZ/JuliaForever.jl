# Replaceable histories

`JuliaForever.History` offers an in-memory store and an adapter over `Durable.Store` with the same append and snapshot operations.

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

`append!` compares the expected revision and atomically appends a nonempty vector as one revision. History revisions count batches; an application defines how they relate to its state-machine revisions. Success returns the new revision. A stale revision returns `Rejected(:revision)` and an empty batch returns `Rejected(:empty_batch)`; neither changes history. The durable transaction serializes competing appends through the underlying store. A snapshot copies all batches and preserves their boundaries, and each iteration returns detached records in order. Later writes and mutations to the input, a returned batch, or a previously iterated record cannot alter the snapshot. It can be passed directly to `Logs.json` and `Logs.html`.

Supported records consist recursively of `nothing`, `Bool`, `Int`, finite `Float64`, valid UTF-8 `String`, Julia `Vector`s, and `Dict`s with valid UTF-8 `String` keys. Container element types and object identity are not preserved: arrays are returned as `Vector{Any}` and objects as `Dict{String, Any}`. Cycles, other numeric and string types, tuples, symbols, structs, and other values return `Rejected(:unsupported_value)` for the whole batch. The journal encodes integer values and floating-point bits explicitly to preserve `Int`, `Float64`, and signed zero despite JSON number parsing. The optional agent integration uses a separate versioned codec for the built-in conversation and kernel events; see [conversation transitions](conversation.md). Extension types need an explicit codec and arbitrary Julia objects are not serialized.

The journal stores each history in a durable document under a private format marker; do not modify that document outside this adapter. It retains the ID across close and reopen. It inherits the [durable store](durable.md)'s exclusive single-process file ownership, `fsync` and recovery behavior, failed-store handling, platform support, and limitations. Opening on unsupported platforms, including Windows, returns `D.Rejected(:unsupported_platform)`. History operations on a closed or failed store return `H.Rejected` with the corresponding reason. Each append currently replaces the complete document, so time, memory, and log size grow with history; there is no compaction or performance claim.

After a write or sync failure, the batch outcome can be uncertain: close and reopen the store and inspect its revision and batches before deciding what to do. Other writers may have continued after recovery, so application-level identity and reconciliation can still be necessary. Histories only record data: reading and replaying them never dispatches effects, and storing a plan does not establish whether any external effect happened or provide exactly-once execution. The agent can opt into either adapter; it does not automatically retry or reconcile external work.
