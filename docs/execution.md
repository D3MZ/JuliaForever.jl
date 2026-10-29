# Native execution

`JuliaForever.Execution` runs typed work in a bounded, ephemeral executor. It does not own task state, persist requests or results, retry work, or replace the transition kernel. A supervisor supplies a stable effect ID and attempt number and decides whether an outcome is still current before applying it to durable state.

Define a work type and a method on each process that may run it:

```julia
using JuliaForever, Distributed
const E = JuliaForever.Execution

struct Double
    value::Int
end
E.perform(work::Double, cancellation::E.Cancellation) = 2 * work.value

executor = E.Executor(myid(); capacity=2)
handle = E.submit!(executor, "effect-1", 1, Double(21))
outcome = fetch(handle) # E.Completed("effect-1", 1, myid(), 42)
close(executor)
```

Each executor argument is a worker slot; repeat a process ID to allow several in-flight jobs on that process. `myid()` runs locally on Julia tasks. Other IDs must be existing `Distributed` workers. The package and the work type and its `perform` method must be loaded on each worker before submission; work and returned values must be serializable by Julia. The executor neither starts nor enrolls machines. Matching code, environments, Julia versions, and process connectivity are the caller's responsibility.

`submit!` blocks when the bounded queue is full. The bound applies to waiting requests; up to one additional request runs per worker slot. `fetch(handle)` waits for a typed `Completed`, `Failed`, or `Cancelled` result and may be repeated. Outcomes carry the supplied `id`, `attempt`, and assigned process ID. Dispatch errors, including worker exceptions and observed process exits, are reported as `Failed` with a diagnostic message. A failed worker slot is not replaced; recreate the executor to change its processes. This is not a guarantee that the work produced no effects: a worker can fail after acting but before reporting its result. Duplicate IDs and retries are allowed; the supervisor owns deduplication, attempt selection, and any reconciliation.

`cancel!(handle)` requests cancellation. Work still in the queue is skipped when a worker sees the request. Running methods may check `E.cancelled(cancellation)` and return `E.Stopped()` to report cooperative cancellation. A method that ignores the request can complete normally, and neither cancellation nor a failure rolls back effects. The signal is hosted by the submitting process, so its availability depends on that process and Julia's connection to it.

`close(executor)` closes admission and waits for queued and running work to finish. It can therefore wait indefinitely for uncooperative work or a broken connection. It does not shut down `Distributed` workers. This foundation does not provide durable delivery, remote enrollment, authentication, authorization, isolation, forced termination, leases, or exactly-once execution.

## Kernel effects

`Kernel.Pending` can be submitted directly without wrapping its effect. Define a `perform` method for the effect type on each worker, then translate the outcome under the supervisor's policy:

```julia
using JuliaForever, Distributed
import JuliaForever.Execution as E
import JuliaForever.Kernel as K

E.perform(effect::K.Call{Int}, cancellation::E.Cancellation) = 2 * effect.input
planned = K.step(K.State("conversation"), K.Plan(0, "double", K.Call("double", 21)))
executor = E.Executor(myid())
completed = fetch(E.submit!(executor, only(planned.effects), 1))
observed = K.step(planned.state, K.Observe(planned.state.revision, completed.id, K.Return(completed.value)))
close(executor)
```

This example handles a successful result only. The supervisor decides whether to observe `Failed` or `Cancelled`, retry, or reconcile an uncertain effect, and must verify the current revision and attempt before recording an outcome. Submitting an effect does not persist the plan or its observation.

## Conversation effects

A worker can execute `Conversation.ModelRequest`, `ToolRequest`, and `SkipRequest` with capabilities installed in that process. A context contains the live provider, an iterable of tool values, and provider parameters; the submitted `Work` contains only its context ID and the typed effect. Install the same fresh, non-secret ID independently on every worker that an executor may select. `install!` returns `false` if that ID is already installed on the process. `uninstall!` removes the context for subsequent lookups.

```julia
using JuliaForever, Distributed
import JuliaForever.Execution as E
import JuliaForever.Conversation as C
import JuliaForever.Kernel as K

# Construct model and tools in this process, using its own configuration.
E.install!(context_id, model, tools; parameters=Dict())
executor = E.Executor(myid())
started = K.step(C.State("session"), C.Input(0, "Hello"))
outcome = fetch(E.submit!(executor, only(started.effects), 1, context_id))
if outcome isa E.Completed
    observed = K.step(started.state, K.Observe(started.state.revision, outcome.id, outcome.value))
end
close(executor)
E.uninstall!(context_id)
```

For a remote process, load JuliaForever and create and install that process's capabilities there before dispatch. Provision credentials using the deployment's own trusted process setup; the adapter does not provision credentials or protect Julia's interprocess traffic. Do not serialize a provider or credentials in an effect, event, work item, or remote installation call. Context IDs identify capabilities, not an authorization boundary. Conversation messages, observations, and tool results still travel between the supervisor and worker and may themselves contain sensitive data; providers and tools must not put credentials in their outputs. All workers in a pool need the same intended capabilities for that ID. Use a new ID for each context lifetime and drain or resolve its admitted work before uninstalling; never reuse an ID for another context while old work might still run. Existing in-flight calls retain their context after uninstall. Concurrent calls share the installed provider and tool objects, which must support the chosen concurrency.

The adapter invokes the provider's non-streaming `complete` method and preserves its assistant message metadata, finish reason, and completion status in `ModelReply`. In particular, Responses `response_output` items survive the next model request. The existing `ModelReply` type does not carry `Completion.usage` or `Completion.error`. A provider exception yields `ModelFailure("provider did not return")` without copying its diagnostic into the observation; a missing context or dispatch failure yields `Execution.Failed`. Explicit tool failures, unknown names, invalid call envelopes or JSON, and operating-system errors become error `ToolReply` values; other exceptions become `Execution.Failed` with a diagnostic and stack. Successful tool results retain their text and error flag. `SkipRequest` returns the truncated-call error without executing the tool. A provider's incomplete result becomes an incomplete model reply and does not run its proposed tools. Queued cancellation is honored before dispatch, but the adapter does not interrupt a running provider or tool. A completed or failed effect may already have caused external actions.

## Agent execution

An agent can explicitly use the adapter after the caller installs a context on every executor process:

```julia
history = JuliaForever.History.Memory() # optionally use another History.Store
agent = Agent(nothing, []; history) # capabilities are installed independently on each worker
result = respond!(agent, "Hello"; executor, context=context_id)
result.value # final text, :cancelled, or an explicit failure result
result.models # ordered ModelResult values, including per-call usage and provider error metadata
```

The caller owns the executor and its contexts. The agent dispatches sequentially and makes no retries or fallback to its local provider. An `Execution.Turn` contains the final value and ordered `ModelResult` values. Each model result contains its typed observation, usage, and provider error metadata. These results are ephemeral: usage and errors are not in replayed events, and provider error text can contain sensitive data. Assistant metadata, finish reason, completion status, tool results, and transitions remain in the replayable event stream. A provider exception instead produces a redacted `ModelFailure` and `Execution.Rejected(:provider_failure)`; an incomplete reply produces `Execution.Rejected(:incomplete_model)` and retains the partial observation and provider error in the turn. An `Execution.Failed` identifies dispatch or worker failure.

The path rejects stream callbacks, per-call parameters, and parallel tool execution with `Execution.Rejected` before starting a turn. Supply parameters through the installed context. Lifecycle callbacks remain supported. A rejected preflight request has no events or effects; a request on a running agent returns `:busy`.

With a history, each transition and its emitted requests are committed before dispatch, and a result is committed before the next request is dispatched. Storage failures stop dispatch; a thrown append leaves the agent latched as `History.Rejected(:uncertain)` and requires reopening. When a worker or submission fails with a pending effect, the turn returns `Execution.Uncertain(cause)`, retaining the underlying failure diagnostic. After worker loss or an interruption, pending effects remain unresolved and the agent rejects later turns with `History.Rejected(:uncertain_effect)`. Reopening and replaying the history does not dispatch work. Once the caller has inspected and reconciled effects and ensured the old work has stopped, `abandon!` records that decision before a new turn. Only one driver may own a history at a time; revision checks do not provide worker leases or exactly-once execution.

`cancel!(agent)` signals admitted work and prevents later work from starting. Even if its history append fails, it signals the work and reports or propagates the storage failure. The adapter cannot stop a running provider or tool; an in-flight completion is observed before the turn stops when the history remains writable. Queued work may be cancelled, while a result already executing may have caused an effect. With no history, worker loss, submission failure, callbacks that throw, and other interruptions leave an incomplete in-memory conversation. No durable worker leases, automatic retry, transport security, authentication, isolation, or exactly-once execution are supplied.
