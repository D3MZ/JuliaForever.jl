# Conversation transitions

`JuliaForever.Conversation` builds a typed conversation state on `Kernel`. The transition layer chooses the next model or tool requests; it does not run them. The caller supplies user input and observations, commits accepted transitions if durability is needed, and dispatches the emitted requests to its executor.

```julia
using JuliaForever
import JuliaForever.Kernel as K
import JuliaForever.Conversation as C

state = C.State("session-1")
started = K.step(state, C.Input(state.revision, "Hello"))
state = started.state
model = only(started.effects) # C.ModelRequest containing a transcript snapshot

# The model result is data received from an external executor.
answer = C.ModelReply(C.Assistant("Hello", C.ToolCall[], "stop", true))
finished = K.step(state, K.Observe(state.revision, model.id, answer))
finished.state.phase == C.Complete
```

Messages are `User`, `Assistant`, and `ToolMessage` values. A completed assistant reply with tool calls emits a `ToolRequest` for each call. Results can arrive in any order: the transcript records them in the assistant's call order, and only then emits the next `ModelRequest`. A tool failure becomes an error tool message. A reply with finish reason `length` records errors for its tool calls without emitting tool requests, then asks the model again. An incomplete model result stops in `Incomplete` without adding its partial assistant message to the transcript.

`Assistant` accepts an optional `metadata` dictionary for provider-specific fields such as Responses `response_output`, including encrypted reasoning and tool items. The constructor copies that dictionary, and subsequent transcript and request snapshots preserve it. The driver must reconstruct provider messages with those fields when it handles a `ModelRequest`.

`Steer` and `Followup` transitions queue text. The next model request consumes at most one steering message; a followup is consumed when a model reply has no tool calls and no steering remains. A new `Input` is accepted from `Ready`, `Complete`, or `Incomplete`, not while a request is pending. Accepted conversation transitions advance the conversation revision once, including queue updates. The nested kernel has its own revision for plans and observations. Use the conversation revision when constructing `Input`, `Steer`, `Followup`, or `Observe`; effect IDs come from emitted `Pending` values. Exact retries of recorded observations are idempotent even after the conversation moves on; conflicting observations and stale new events are rejected.

`K.Replay(C.State(id), events)` runs these same decisions as a finite, repeatable iterator. A replay emits the same request data but invokes no model or tool. The transcript and emitted requests are detached snapshots; native Julia effect types can be dispatched by an external executor. The model and tool requests contain no provider object, credentials, tasks, or channels.

`Agent.respond!` drives these transitions. `agent.state` is its current conversation state, `agent.initial` is its initial snapshot, and `agent.events` returns detached event data. `K.Replay(agent.initial, agent.events)` reconstructs the conversation without invoking the provider or tools. The driver uses explicit `Advance` events to make its next decision after lifecycle callbacks have run, and it records changes to the public `agent.messages` transcript as `History` events. An interrupted provider or callback leaves an incomplete state that can accept a later turn. Truncated calls become `SkipRequest` values that the driver resolves as errors without invoking the tools.

Provider and tool execution currently runs in the caller, with optional local threaded tool execution; `Agent` is not yet wired to `Durable.Store` or a distributed executor. A durable driver must persist each accepted event and its resulting state atomically before dispatching any newly planned effect, reconcile uncertain external effects, and avoid dispatching replay output. Neither observation deduplication nor replay guarantees exactly-once execution. Serialization, worker leases, cross-machine retries, and durable execution recovery are not implemented. Provider objects, tool instances, and per-call parameters remain driver configuration rather than recorded request data.
