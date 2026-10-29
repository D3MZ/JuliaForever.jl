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

Messages are `User`, `Assistant`, and `ToolMessage` values. A completed assistant reply with tool calls emits a `ToolRequest` for each call. Results can arrive in any order: the transcript records them in the assistant's call order, and only then emits the next `ModelRequest`. A tool failure becomes an error tool message. `ToolReply` and `ToolMessage` can also carry one optional `Image` alongside their text; the image remains part of the observation and replayed transcript. A reply with finish reason `length` records errors for its tool calls without emitting tool requests, then asks the model again. An incomplete model result stops in `Incomplete` without adding its partial assistant message to the transcript.

`Assistant` accepts an optional `metadata` dictionary for provider-specific fields such as Responses `response_output`, including encrypted reasoning and tool items. The constructor copies that dictionary, and subsequent transcript and request snapshots preserve it. The driver must reconstruct provider messages with those fields when it handles a `ModelRequest`.

`Steer` and `Followup` transitions queue text. The next model request consumes at most one steering message; a followup is consumed when a model reply has no tool calls and no steering remains. A new `Input` is accepted from `Ready`, `Complete`, or `Incomplete`, not while a request is pending. Accepted conversation transitions advance the conversation revision once, including queue updates. The nested kernel has its own revision for plans and observations. Use the conversation revision when constructing `Input`, `Steer`, `Followup`, or `Observe`; effect IDs come from emitted `Pending` values. Exact retries of recorded observations are idempotent even after the conversation moves on; conflicting observations and stale new events are rejected.

`K.Replay(C.State(id), events)` runs these same decisions as a finite, repeatable iterator. A replay emits the same request data but invokes no model or tool. The transcript, pending message data, and emitted requests are detached snapshots; native Julia effect types can be dispatched by an external executor. Live task handoffs use Julia channels, while the replayable state holds values so earlier revisions remain unchanged. The model and tool requests contain no provider object, credentials, tasks, or channels.

`Agent.respond!` drives these transitions. `agent.state` is its current conversation state, `agent.initial` is its initial snapshot, and `agent.events` returns detached event data. `K.Replay(agent.initial, agent.events)` reconstructs the conversation without invoking the provider or tools. The driver uses explicit `Advance` events to make its next decision after lifecycle callbacks have run, and it records changes to the public `agent.messages` transcript as `History` events. An interrupted provider or callback leaves an incomplete state that can accept a later turn. Truncated calls become `SkipRequest` values that the driver resolves as errors without invoking the tools.

An agent can opt into a replaceable `History.Store`:

```julia
import JuliaForever.History as H
import JuliaForever.Durable as D

store = open(D.Store, "history.jsonl")
history = H.create(store)
id = history.id                         # retain the ID for reopening
agent = Agent(provider, tools; history)
answer = respond!(agent, "Hello")
close(store)

store = open(D.Store, "history.jsonl")
agent = Agent(provider, tools; history=H.Journal(store, id))
replay = K.Replay(agent.initial, agent.events) # passive, repeatable
```

The constructor records the initial transcript in an empty history or restores an existing history by validating and replaying its events; supplying nonempty initial messages for an existing history returns `H.Rejected(:history_exists)`. Use only one active driver for a history at a time. Each accepted transition is appended with a revision check before the in-memory state advances and before any emitted model or tool request is dispatched. History append, unsupported-value, and revision failures return `H.Rejected` and latch the agent; reopen and inspect the history before deciding what to do. A failed durable write can have an uncertain outcome. An unknown event format, malformed record, or invalid event sequence is rejected. Recorded mode supports sequential tool execution; `tool_execution=:parallel` returns `H.Rejected(:unsupported_execution)` for the local driver and `Execution.Rejected(:parallel_tools)` for the executor before starting a turn. The legacy constructor without `history` retains its existing behavior, including local parallel tools.

After restart, a pending request causes `respond!` to return `H.Rejected(:uncertain_effect)`. An interrupted turn with no pending request returns `H.Rejected(:incomplete_turn)`. Neither case automatically repeats a request. Once the caller has inspected and reconciled external effects, `abandon!(agent, "reason")` explicitly records abandonment and permits a new turn; it does not cancel or undo any external action. For unresolved tool calls, it records ordered tool messages stating that the outcome is unknown and the call was abandoned, preserving any already observed results. A distinct `Abandon` event preserves the replay behavior of older `Interrupt` records. These boundaries also apply to an exception during recorded execution. The caller must ensure no earlier executor is still running before abandoning a turn. Reopening is required after an append failure or conflict; abandonment does not repair storage or resolve a conflicting writer.

`History.encode` and `History.decode_event` use a versioned, explicit codec for built-in conversation and kernel events. Metadata supports `nothing`, `Bool`, `Int`, finite `Float64`, valid `String`, and Julia `Vector`s and `Dict{String,T}` whose element types are `Any`, one of those concrete scalar types, or a recursively supported container type. Container types and floating-point bits are preserved; union and abstract element types other than `Any` are unsupported. Other values and cycles return `H.Rejected(:unsupported_value)` rather than being coerced. Native extension event types require a codec extension before they can be recorded. The event stream contains transcripts, tool arguments/results and provider response metadata, so it can itself contain sensitive information. Provider objects, credentials stored on those objects, tool instances, callbacks, and per-call parameters are not stored as configuration.

The default and recorded drivers run provider and tool execution in the caller. The explicit executor-backed path in [native execution](execution.md) can also use a recorded agent. None of these paths provides a worker lease, automatic retry, or exactly-once guarantee. Replay emits descriptions and never dispatches them. Store exclusivity and recovery limits are described in [replaceable histories](history.md). The drivers have separate execution paths, whose behaviors must be maintained and tested separately.
