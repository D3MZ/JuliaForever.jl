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

`D.snapshot(store, conversation, document, entry)` returns a detached `Document` as it stood at the end of the entry's committed batch, or `nothing` if the document did not yet exist in that conversation. An entry outside that conversation returns `Rejected(:entry_not_visible)`. The result is rebuilt on reopen; the returned record distinguishes a missing document from a document whose value is `nothing`.

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

These forks have no ownership edge or inherited tasks or submissions. They can also copy explicitly policy-bearing conversation documents:

```julia
D.commit!(store) do tx
    id = D.mint!(tx)
    D.put!(tx, D.PolicyDocument(id, conversation, "notes", nothing, D.AsOf(), Dict("text" => "hello")))
end
```

A policy document has a globally distinct ID and an immutable `(conversation, kind, key, policy)`. A `nothing` key denotes a singleton; string keys denote family members, and `""` is distinct from `nothing`. The logical address `(conversation, kind, key)` is unique. Full-value updates keep the same identity; reads and copies are detached. All policy documents retain rewindable full-value history.

`D.AsOf()` selects the document in the fork entry's owning conversation as it stood at the end of that entry's commit. `D.Current()` selects the immediate parent's current document. `D.Initial()` leaves that address absent in the child; the caller may create it later. Selected documents receive new IDs and are copied atomically with the child, and later updates are independent. If both selections target the same child address, the fork returns `Rejected(:fork_document_address_in_use)`. An entry from an ancestor remains subject to the parent's visibility cutoff; the child's `parent` still records the immediate parent and selected entry. Unrelated conversations are unaffected.

The original `D.Document` has no policy metadata and remains unsupported for forks: a document in the parent or any ancestor returns `Rejected(:fork_documents_unsupported)`. Direct writes of parented `Conversation` records retain the same conservative guard for both document kinds. `fork!` is the policy-aware path. A fork rejects a transaction that also writes a policy document in its parent or any ancestor with `Rejected(:fork_source_modified)`, including writes before or after the fork; a staged opaque document is also rejected. This is deliberately stricter than Pi for unrelated policy documents in those conversations. Copy identities, source selection, and these batch rules are revalidated on replay.

This slice does not implement document retirement and recreation, latest-only history retention, versions or migrations, deltas, initialization callbacks, session/task-scoped documents, Pi storage-format compatibility, transcript heads, or pagination. Pi's collision case involving retired and recreated documents therefore cannot yet be represented. `D.snapshot` still accepts only an entry owned by the document's conversation; inherited-entry snapshots are used internally for fork selection and are not exposed as a public inherited-document snapshot API.

`Store.failed`, `Store.closed`, `Store.busy`, and `Transaction.active` remain Boolean properties. Their internal fields now use typed lifecycle states; code using `getfield` or field reflection must use the properties instead.

One process owns the file through an advisory exclusive `flock`; nested commits, transaction access from another Julia task, and use of a transaction after its callback are rejected. All readers and writers must use this store and must not replace the file while it is open. On platforms without Unix `flock`, opening returns `Rejected(:unsupported_platform)`; this implementation has only been tested on macOS.

Each committed batch is one newline-terminated JSON record. The store flushes and calls `fsync` before adopting it in memory; when creating a file it also syncs its parent directory. Reopening replays complete records in order, removes an incomplete trailing line, and rejects a malformed complete line without truncating it. If a storage operation fails, the open store is failed and must be closed and reopened: a complete batch may or may not have reached disk. A retry with the same request key resolves an admission whose outcome was uncertain. These checks cover abrupt process exit and controlled torn tails, not hardware power-loss qualification. OS and filesystem errors propagate normally.

The internal `Durable.replay!` now returns `nothing` on success or `Rejected(:corrupt_log)` on failure; earlier versions returned a Boolean.

The implementation reads the log into memory at open and copies its in-memory state for a transaction; it has no compaction or performance claims. The independent [task scheduler foundation](scheduler.md) uses this store for explicit checkpointed phase execution and reopen recovery. `History.Journal` also adapts the store for recorded agent transitions; the transcript fork API is not integrated into the agent loop. Document snapshots are available at an entry's commit within the document's own conversation; deltas, retirement and a public inherited-document history API remain unsupported. Submission transition rules, observers and deferred commits are also absent. External effects must occur outside a transaction and need their own idempotency; durable admission alone does not make effects exactly once.

Run its synthetic tests with Julia 1.12 or newer:

```sh
JULIA_NUM_THREADS=4 julia --project=. test/durable.jl
JULIA_NUM_THREADS=4 julia --project=. test/durable_forks.jl
```

The optional `test/durable_forks_differential.jl` and `test/durable_policy_forks.jl` use `PI_SOURCE` pointing to the pinned Pi checkout and Node's source condition to compare transcript and document-policy behavior against Pi's memory-backed session. The current-policy comparison covers fork values, not latest-only retention. The Pi address-collision case retires and recreates a document; the native selector comparison uses an equivalent hypothetical in-memory state because native retirement is unsupported. Pi is a test oracle, not a runtime dependency.
