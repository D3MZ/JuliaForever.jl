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
