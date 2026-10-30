# Durable task scheduler foundation

`JuliaForever.Durable.Scheduler` runs explicitly supplied Julia handlers over the JSONL store. It is independent of the provider and tool loop. A handler decodes a persisted checkpoint to a Julia `Phase` subtype, and ordinary Julia dispatch selects the phase implementation:

```julia
using JuliaForever
import JuliaForever.Durable as D

struct Example <: D.Handler end
struct Work <: D.Phase
    offset::Int
end

D.name(::Example) = "example"
D.encode(phase::Work) = D.Checkpoint("work", phase.offset)
D.decode(::Example, checkpoint::D.Checkpoint) = Work(checkpoint.value)
Base.run(::Example, phase::Work, input, invocation::D.Invocation) = D.Complete(input + phase.offset)

scheduler = open(D.Scheduler, "tasks.jsonl")
conversation = D.commit!(scheduler.store) do tx
    id = D.mint!(tx)
    D.put!(tx, D.Conversation(id, nothing))
    id
end
id = D.enqueue!(scheduler, conversation, Example(), Work(2), 40; request="example-1", maxattempts=3)
result = D.step!(scheduler, id, Example())
result.status.value  # 42
close(scheduler)
```

A `Next(phase)` result durably stores a changed checkpoint and returns the task to `Pending`; returning the same checkpoint counts as a retry, retaining its attempt count and phase identity. `Complete(value)` stores a terminal result. `Retry(message)` retains the checkpoint and records a retryable failure, while `Fail(message)` ends the task. Each `step!` runs at most one phase; the host chooses and invokes pending tasks. `maxattempts` bounds attempts **per checkpoint**, including calls interrupted after the running reservation; advancing to `Next` resets the attempt count. Exhaustion produces `Failed(:attempt_limit)`. Unexpected exceptions, including decoding, handler, serialization and storage failures, propagate normally. If the running reservation committed but the outcome did not, close and reopen to recover it. Such a reopen counts as an interruption even if the handler had thrown and the subsequent close was clean.

`get(scheduler, id)` and `D.scan(scheduler; conversation)` return detached `TaskView` values with typed `Pending`, `Running`, `Completed`, `Failed`, or `Cancelled` statuses. `D.enqueue!` returns a task ID. A request key deduplicates only scheduler tasks in the same conversation: the original kind, input, initial checkpoint, and attempt limit must match after JSON serialization, or admission returns `Rejected(:request_conflict)`. A missing key creates a separate task each time. These request keys do not deduplicate `Submission` records or effects in external systems.

`Running` is an abstract status with `Active` and `Cancelling` subtypes. `Running(false)`, `Running(true)`, and the `cancelled` property remain available.

A scheduler owns its store and obtains the store's exclusive file lock. The host must not directly mutate scheduler task records or close its store; use the scheduler operations while it is open. A phase reservation is committed before handler code runs. Calls racing on the same task cannot both reserve it, and handlers for different tasks can run concurrently. The handler runs outside the store transaction; the result is committed afterward. `close` returns `Rejected(:busy)` while any invocation is running and does not interrupt it. A scheduler does not start worker threads, poll, or schedule retries; the host supplies handlers and calls `step!` again.

`cancel!` commits cancellation immediately for a pending task. For a running task it durably marks cancellation; the handler is not signalled or interrupted, and its result is discarded when it returns. Cancellation cannot undo effects already underway. On reopen an interrupted, cancellation-marked task becomes `Cancelled` without rerunning. Otherwise, reopening a running task counts a restart and returns it to `Pending`, or fails it if its attempt limit was reached. `restarts` counts interruptions across the entire task, including previous phases; it is not Pi's consecutive-restarts counter.

The scheduler uses **at-least-once retry semantics**: a process may die after the effect and before the outcome commit, so a handler can be called again for the same phase. An effect can also happen zero times if cancellation, attempt exhaustion, or a crash prevents it; this is not an eventual-delivery guarantee. `Invocation.task` and `Invocation.phase` remain stable across retries, while `Invocation.attempt` increases. A handler can combine the task and phase with its own stable store or application namespace as an external idempotency key, or reconcile an external operation before repeating it. Neither durable admission nor cancellation makes an external effect transactional with this JSONL store.

Opening uses the existing store's Unix advisory `flock`, `fsync`, and complete-line replay. It returns `Rejected(:locked)` when another owner has the file and `Rejected(:unsupported_platform)` where Unix `flock` is unavailable. All accessors must use the same store and callers must not replace the file while it is open. Tests were run on macOS; hardware power-loss durability and other Unix platforms are unverified. There is no log compaction or performance claim.

The design was compared with Pi's pinned durable task types and effect sandwich (Pi revision `e7a0df27c09d11bf4161d3605246cbf57a129cb2`, `packages/durable/docs/spec.md` sections 5.1–5.4). This is not Pi format or harness compatibility. It has no registry or version migration, automatic dispatch, time-based retries or sleeping, joins or task ownership, structured cancellation cascades, abort handlers, live observers, memos, read-only harness, deferred commits, submission settlement, agent/model integration, Cloudflare deployment, or Pi's restart-limit policy. There are no user or model calls in the tests.

```sh
JULIA_NUM_THREADS=4 julia --project=. test/scheduler.jl
```
