# Durable storage foundation

`JuliaForever.Durable` does not depend on the provider or tools. It implements a small storage boundary informed by the pinned Pi durable specification, not the Pi storage format or the full Pi harness.

```julia
using JuliaForever
import JuliaForever.Durable as D

store = open(D.Store, "session.jsonl")
conversation, submission = D.commit!(store) do tx
    conversation = D.mint!(tx)
    D.put!(tx, D.Conversation(conversation, Dict("name" => "example")))
    submission = D.submit!(tx, conversation; request="request-1", kind="input", value=Dict("text" => "hello"))
    (conversation, submission)
end

get(store, D.Submission, conversation, "request-1")
D.scan(store, D.Task; conversation)
close(store)
```

Records are conversations, entries, tasks, documents, and submissions. A transaction mints globally distinct numeric IDs, reads its own staged writes, and commits all writes as one batch. Conversation and entry records are immutable; task, document, and submission records are full replacements retaining their identity and conversation. JSON values are detached on write and on every read. `scan` returns records in ID order and can filter by conversation. A failed callback, invalid write, or failed return-value copy stores none of its batch. Invalid operations return `Rejected`, and a rejection inside a transaction rejects its whole batch even if the callback ignores it.

A submission request key is scoped to a conversation. Retrying the same key and kind returns the original ID even if the new value differs; it does not create a commit. Reusing the key for a different kind rejects the transaction. `nothing` means no deduplication key. The store keeps submission data but does not execute or settle submissions.

## Transcript forks

```julia
entry = D.commit!(store) do tx
    id = D.mint!(tx)
    D.put!(tx, D.Entry(id, conversation, "input", "hello"))
end
child = D.commit!(store) do tx
    D.fork!(tx, conversation, entry; value=Dict("name" => "branch"))
end
D.entries(store, child)  # inherited entries followed by the child's entries
```

`fork!` creates an immutable child conversation whose `parent` is the pair `(conversation, entry)`. The entry must already be committed and visible from that parent, including through an ancestor. Each ancestor is capped at its fork entry, inclusive. `entries` returns detached entries oldest first, and `entries(tx, child)` also sees staged writes. The existing `scan(store, D.Entry; conversation=child)` still returns only the child's own entries. Missing conversations and invisible or uncommitted fork points return `Rejected(:conversation_missing)` and `Rejected(:fork_point_missing)` respectively, rejecting the complete transaction. Reopening retains the same ancestry and validates its references.

These are transcript-only forks, with no ownership edge or inherited tasks or submissions. Document history and fork policies are not implemented: creating a fork returns `Rejected(:fork_documents_unsupported)` if the parent or any ancestor has a document at admission, including one staged in the same batch. This conservative check also applies to direct writes of parented conversations and to log replay; unrelated documents do not block a fork. Adding a document later does not change an existing fork's transcript, but prevents further forks from that ancestry. The store cannot infer `asOf`, `current`, or `initial` document behavior from its current document records. It also does not implement transcript heads, pagination, or Pi storage-format compatibility.

`Store.failed`, `Store.closed`, `Store.busy`, and `Transaction.active` remain Boolean properties. Their internal fields now use typed lifecycle states; code using `getfield` or field reflection must use the properties instead.

One process owns the file through an advisory exclusive `flock`; nested commits, transaction access from another Julia task, and use of a transaction after its callback are rejected. All readers and writers must use this store and must not replace the file while it is open. On platforms without Unix `flock`, opening returns `Rejected(:unsupported_platform)`; this implementation has only been tested on macOS.

Each committed batch is one newline-terminated JSON record. The store flushes and calls `fsync` before adopting it in memory; when creating a file it also syncs its parent directory. Reopening replays complete records in order, removes an incomplete trailing line, and rejects a malformed complete line without truncating it. If a storage operation fails, the open store is failed and must be closed and reopened: a complete batch may or may not have reached disk. A retry with the same request key resolves an admission whose outcome was uncertain. These checks cover abrupt process exit and controlled torn tails, not hardware power-loss qualification. OS and filesystem errors propagate normally.

The internal `Durable.replay!` now returns `nothing` on success or `Rejected(:corrupt_log)` on failure; earlier versions returned a Boolean.

The implementation reads the log into memory at open and copies its in-memory state for a transaction; it has no compaction or performance claims. The independent [task scheduler foundation](scheduler.md) uses this store for explicit checkpointed phase execution and reopen recovery. `History.Journal` also adapts the store for recorded agent transitions; the transcript fork API is not integrated into the agent loop. The store has no document deltas or history, submission transition rules, timers, observers, or deferred commits. External effects must occur outside a transaction and need their own idempotency; durable admission alone does not make effects exactly once.

Run its synthetic tests with Julia 1.12 or newer:

```sh
JULIA_NUM_THREADS=4 julia --project=. test/durable.jl
JULIA_NUM_THREADS=4 julia --project=. test/durable_forks.jl
```

The optional `test/durable_forks_differential.jl` uses `PI_SOURCE` pointing to the pinned Pi checkout and Node's source condition to compare the transcript subset against Pi's memory-backed session. Pi is a test oracle, not a runtime dependency.
