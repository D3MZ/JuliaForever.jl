# State-machine foundation

`JuliaForever.Kernel` models planned effects and observed results as data. It does not execute an effect or require Pi, Node, a provider, a tool, a scheduler, or a particular storage backend.

```julia
using JuliaForever
import JuliaForever.Kernel as K

state = K.State("conversation-1")
planned = K.step(state, K.Plan(0, "read-1", K.Call("read", (path="notes.txt",))))
state = planned.state
intent = only(planned.effects)             # id and effect, not a running task

# An external executor carries out the intent and returns data.
observed = K.step(state, K.Observe(1, intent.id, K.Return("contents")))
state = observed.state
finished = K.step(state, K.Finish(2))
```

Accepted transitions return `Applied(state, effects)` and increment the revision. Planning can leave multiple effects pending. Each effect ID may be used once within a state; observations can arrive in any order. An exact retry of an accepted observation returns `Duplicate` without changing state, including when the retry carries an old revision. An observation with the same ID and different data returns `Rejected(:observation_conflict)`. Other stale transitions, unknown IDs, reuse of an effect ID, and finishing while effects remain pending are also rejected as values. `Finish` closes the state; an exact observation retry still returns `Duplicate` afterward.

The state and events use concrete Julia structures. `State` has the same type as its history grows, and reading `pending` or `observations` returns detached data. Accepted inputs, emitted effects, and observations are copied at the boundary. Native Julia extensions may subtype `Effect` and `Observation`; observation types must implement value-based `isequal` for retry detection. The built-in `Return` and `Fail` compare nested values with their types, so a boolean and an integer do not count as the same result. Payloads must be copyable data, not live tasks, channels, sockets, credentials, or executable callbacks.

`Replay(initial, events)` snapshots a finite vector or tuple of events and implements Julia's iterator protocol. Iterating it repeatedly applies the same transitions and yields each result, stopping after the first rejection. Replay exposes planned effects as data and never dispatches them to an executor. It copies its input history, so later mutation of the original events or values returned from replay does not change subsequent iterations.

This is an in-memory foundation. The existing agent uses the conversation transitions described in [conversation transitions](conversation.md), but this module does not itself provide cross-machine dispatch or recover a running effect. The optional recorded agent uses an explicit versioned codec and replaceable history as described in [conversation transitions](conversation.md). A durable driver must commit plans before dispatch, commit observations with revision checks, and arrange effect-specific idempotency or reconciliation for crashes; deduplicating observations does not make external effects exactly once. No distributed safety, persistence, or performance guarantee follows from these unit tests.
