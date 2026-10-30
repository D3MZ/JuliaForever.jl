function openagent(provider, tools, messages, initial, ::Nothing)
    Agent(provider, tools, messages, initial, initial, Kernel.Event[], ReentrantLock(), Idle(), ShellCancellation(), nothing, nothing, 0, nothing)
end

openagent(provider, tools, messages, initial, history::History.Store) = openagent(provider, tools, messages, initial, history, History.snapshot(history))
openagent(provider, tools, messages, initial, history::History.Store, rejected::History.Rejected) = rejected

function openagent(provider, tools, messages, initial, history::History.Store, snapshot::History.Snapshot)
    if snapshot.revision == 0
        revision = persist!(history, 0, History.encode_initial(initial))
        return openagent(provider, tools, messages, initial, history, revision)
    end
    isempty(messages) || return History.Rejected(:history_exists)
    batches = snapshot.batches
    History.consistent(history, snapshot) || return History.Rejected(:invalid_record)
    all(batch -> length(batch) == 1, batches) || return History.Rejected(:invalid_record)
    initial = History.decode_initial(only(first(batches)))
    restore(provider, tools, history, snapshot, initial, replay(initial, batches[2:end]))
end

openagent(provider, tools, messages, initial, history::History.Store, revision::Integer) = Agent(provider, tools, messages, initial, initial, Kernel.Event[], ReentrantLock(), Idle(), ShellCancellation(), nothing, history, revision, nothing)
replay(rejected::History.Rejected, batches) = rejected

replay(initial::Conversation.State, batches) = replay(initial, batches, getfield(initial, :mode))
replay(initial::Conversation.State, batches, ::Conversation.Automatic) = History.Rejected(:invalid_record)
function replay(initial::Conversation.State, batches, ::Conversation.Manual)
    foldl(batches; init=(initial, Kernel.Event[])) do state, batch
        replay(state, batch)
    end
end

replay(state::Tuple, batch::AbstractVector) = replay(state, History.decode_event(only(batch)))
replay(state::Tuple, rejected::History.Rejected) = rejected
replay(state::Tuple, event::Kernel.Event) = replay(state, event, Kernel.step(first(state), event))
replay(state::Tuple, event::Kernel.Event, result) = History.Rejected(:invalid_record)

function replay(state::Tuple, event::Kernel.Event, result::Kernel.Applied)
    events = last(state)
    push!(events, event)
    result.state, events
end

restore(provider, tools, history::History.Store, snapshot::History.Snapshot, initial, rejected::History.Rejected) = rejected

function restore(provider, tools, history::History.Store, snapshot::History.Snapshot, initial::Conversation.State, replayed::Tuple)
    state, events = replayed
    messages = Dict{String, Any}[convert(Dict{String, Any}, message) for message in state.messages]
    failure = fault(state)
    Agent(provider, tools, messages, initial, state, events, ReentrantLock(), Idle(), ShellCancellation(), nothing, history, snapshot.revision, failure)
end

persist!(agent::Agent, event) = persist!(agent, agent.history, event)
persist!(agent::Agent, ::Nothing, event) = nothing
persist!(history::History.Store, revision::Integer, rejected::History.Rejected) = rejected
persist!(history::History.Store, revision::Integer, record::AbstractDict) = History.append!(history, revision, Any[record])

function record!(agent::Agent, rejected::History.Rejected)
    agent.fault = rejected
end

function record!(agent::Agent, revision::Integer)
    agent.history_revision = revision
    nothing
end

function persist!(agent::Agent, history::History.Store, event)
    complete = false
    try
        result = persist!(history, agent.history_revision, History.encode(event))
        complete = true
        record!(agent, result)
    finally
        complete || (agent.fault = History.Rejected(:uncertain))
    end
end

fault(agent::Agent) = lock(() -> agent.fault, agent.lock)

function fault(state::Conversation.State)
    !isempty(state.kernel.pending) && return History.Rejected(:uncertain_effect)
    fault(state.phase)
end

fault(::Union{Conversation.ReadyModelPhase, Conversation.ReadyDecisionPhase, Conversation.WaitingModelPhase, Conversation.WaitingToolsPhase}) = History.Rejected(:incomplete_turn)
fault(::Conversation.Phase) = nothing

function interrupted!(agent::Agent)
    lock(agent.lock) do
        interrupted!(agent, agent.fault)
    end
end

interrupted!(agent::Agent, ::History.Rejected) = nothing

function interrupted!(agent::Agent, ::Nothing)
    agent.fault = fault(agent.state)
    nothing
end

"Record an explicit decision to abandon an interrupted or uncertain turn; this does not undo external effects."
function abandon!(agent::Agent, reason::AbstractString)
    lock(agent.lock) do
        abandon!(agent, reason, agent.turn, agent.history, agent.fault)
    end
end

abandon!(agent::Agent, reason, ::Union{Running, Cancelled}, history, fault) = History.Rejected(:busy)
abandon!(agent::Agent, reason, ::Idle, ::Nothing, fault) = History.Rejected(:no_history)
abandon!(agent::Agent, reason, ::Idle, ::History.Store, ::Nothing) = History.Rejected(:not_interrupted)

const abandonable = Dict(:uncertain_effect => Conversation.Abandon, :incomplete_turn => Conversation.Abandon)
abandon!(agent::Agent, reason, ::Idle, ::History.Store, fault::History.Rejected) = abandon!(agent, abandon_event(agent, reason, fault, get(abandonable, fault.reason, nothing)))
abandon_event(agent, reason, fault, ::Nothing) = fault
abandon_event(agent, reason, fault, constructor) = constructor(agent.state.revision, String(reason))
abandon!(agent::Agent, rejected::History.Rejected) = rejected
abandon!(agent::Agent, event::Conversation.Abandon) = abandon!(agent, event, Kernel.step(agent.state, event))

abandon!(agent::Agent, event::Conversation.Abandon, result) = History.Rejected(result.reason)

function abandon!(agent::Agent, event::Conversation.Abandon, result::Kernel.Applied)
    agent.fault = nothing
    abandon!(agent, event, result, persist!(agent, event))
end

abandon!(agent::Agent, event::Conversation.Abandon, result, saved::History.Rejected) = (agent.fault = saved)

function abandon!(agent::Agent, event::Conversation.Abandon, result::Kernel.Applied, ::Nothing)
    agent.state = result.state
    push!(getfield(agent, :events), event)
    empty!(agent.messages)
    append!(agent.messages, [convert(Dict{String, Any}, message) for message in result.state.messages])
    result
end

function recorded_tools!(agent, effects, messages, callback)
    foldl(effects; init=Dict{String, Any}[]) do results, effect
        recorded_tool!(agent, effect, messages, callback, results)
    end
end

recorded_tool!(agent, effect, messages, callback, outcome) = outcome

function recorded_tool!(agent, effect, messages, callback, results::Vector{Dict{String, Any}})
    call = convert(Dict{String, Any}, effect.effect.call)
    toolstart(call, callback)
    recorded_tool!(agent, effect, messages, callback, results, call, fault(agent))
end

recorded_tool!(agent, effect, messages, callback, results, call, rejected::History.Rejected) = rejected

function recorded_tool!(agent, effect, messages, callback, results, call, ::Nothing)
    result = toolresult(agent, call, effect.effect, callback)
    recorded_tool!(agent, effect, messages, callback, results, call, result, fault(agent))
end

recorded_tool!(agent, effect, messages, callback, results, call, result, rejected::History.Rejected) = rejected

function recorded_tool!(agent, effect, messages, callback, results, call, result, ::Nothing)
    transition, added = transition!(revision -> Kernel.Observe(revision, effect.id, Conversation.ToolReply(result)), agent)
    recorded_tool!(agent, effect, messages, callback, results, call, result, transition, added)
end

recorded_tool!(agent, effect, messages, callback, results, call, result, transition, added) = transition

function recorded_tool!(agent, effect, messages, callback, results, call, result, transition::Kernel.Applied, added)
    present!(agent, added, messages, callback)
    recorded_tool!(agent, effect, messages, callback, results, call, result, transition, added, fault(agent))
end

recorded_tool!(agent, effect, messages, callback, results, call, result, transition, added, rejected::History.Rejected) = rejected
recorded_tool!(agent, effect, messages, callback, results, call, result, transition, added, ::Nothing) = push!(results, toolmessage(call, result))

function respond_recorded!(agent::Agent, prompt; on_event=nothing, on_agent_event=nothing, parameters=Dict(), tool_execution=:sequential)
    respond_recorded!(agent, prompt, agent.fault; on_event, on_agent_event, parameters, tool_execution)
end

respond_recorded!(agent::Agent, prompt, rejected::History.Rejected; kwargs...) = rejected

respond_recorded!(agent::Agent, prompt, ::Nothing; on_event, on_agent_event, parameters, tool_execution) = recorded_mode!(agent, prompt, toolmode(tool_execution); on_event, on_agent_event, parameters)
recorded_mode!(agent, prompt, mode; kwargs...) = History.Rejected(:unsupported_execution)

function recorded_mode!(agent, prompt, ::Sequential; on_event, on_agent_event, parameters)
    begin!(agent) || return :busy
    messages = Dict{String, Any}[]
    event_lock = ReentrantLock()
    callback = on_agent_event
    on_agent_event = event -> lock(() -> emit(callback, event), event_lock)
    run = (; agent, on_event, callback=on_agent_event, parameters, messages)
    try
        emit(on_agent_event, (; type=:agent_start))
        emit(on_agent_event, (; type=:turn_start))
        recorded_begin!(run, prompt, agent.fault)
    finally
        try
            interrupted!(agent)
            emit(on_agent_event, (; type=:agent_end, messages=deepcopy(messages)))
        finally
            finish!(agent)
        end
    end
end

recorded_begin!(run, prompt, rejected::History.Rejected) = rejected
recorded_begin!(run, prompt, ::Nothing) = recorded_input_sync!(run, prompt, sync!(run.agent))
recorded_input_sync!(run, prompt, rejected::History.Rejected) = rejected

function recorded_input_sync!(run, prompt, ::Nothing)
    result, added = transition!(revision -> Conversation.Input(revision, prompt), run.agent)
    recorded_input!(run, result, added)
end

recorded_input!(run, result, added) = result
function recorded_input!(run, result::Kernel.Applied, added)
    present!(run.agent, added, run.messages, run.callback)
    recorded_cancel!(run, run.agent.fault)
end

recorded_cancel!(run, rejected::History.Rejected) = rejected
function recorded_cancel!(run, ::Nothing)
    agent = run.agent
    recorded_cancelled!(run, cancel_transition!(agent, turnstate(agent)))
end

recorded_cancelled!(run, result) = result
recorded_cancelled!(run, ::Union{Nothing, Kernel.Applied}) = recorded_advance_sync!(run, sync!(run.agent))
recorded_advance_sync!(run, rejected::History.Rejected) = rejected

function recorded_advance_sync!(run, ::Nothing)
    result, added = transition!(revision -> Conversation.Advance(revision), run.agent)
    recorded_advance!(run, result, added)
end

recorded_advance!(run, result, added) = result
function recorded_advance!(run, result::Kernel.Applied, added)
    present!(run.agent, added, run.messages, run.callback)
    recorded_ready!(run, result, run.agent.fault)
end

recorded_ready!(run, result, rejected::History.Rejected) = rejected
recorded_ready!(run, result, ::Nothing) = recorded_ready!(run, result, turnstate(run.agent))
function recorded_ready!(run, result, ::Cancelled)
    emit(run.callback, (; type=:turn_end, message=nothing, tool_results=Dict{String, Any}[]))
    :cancelled
end
recorded_ready!(run, result, ::Union{Idle, Running}) = recorded_loop!(run, only(result.effects))
turnstate(agent::Agent) = lock(() -> agent.turn, agent.lock)

function recorded_loop!(run, effect)
    pending = Kernel.Pending[effect]
    result = Ref{Any}()
    while !isempty(pending)
        next = recorded_step!(run, pop!(pending), turnstate(run.agent))
        schedule_pending!(pending, result, next)
    end
    result[]
end

schedule_pending!(pending, result, next::Kernel.Pending) = push!(pending, next)
schedule_pending!(pending, result, value) = (result[] = value)

function recorded_step!(run, effect, ::Cancelled)
    result, _ = transition!(revision -> Kernel.Observe(revision, effect.id, Conversation.ModelFailure("cancelled before dispatch")), run.agent)
    recorded_cancel_observed!(run, result)
end
recorded_cancel_observed!(run, result) = result
function recorded_cancel_observed!(run, ::Kernel.Applied)
    emit(run.callback, (; type=:turn_end, message=nothing, tool_results=Dict{String, Any}[]))
    :cancelled
end

function recorded_step!(run, effect, ::Union{Idle, Running})
    request = [convert(Dict{String, Any}, message) for message in effect.effect.messages]
    answer = response(run.agent, request, run.parameters, run.on_event, run.callback)
    recorded_answer!(run, effect, answer, run.agent.fault)
end

recorded_answer!(run, effect, answer, rejected::History.Rejected) = rejected
function recorded_answer!(run, effect, answer, ::Nothing)
    outcome = conversation_reply(answer)
    result, added = transition!(revision -> Kernel.Observe(revision, effect.id, outcome), run.agent)
    recorded_observed!(run, answer, result, added)
end

recorded_observed!(run, answer, result, added) = result
recorded_observed!(run, answer, result::Kernel.Applied, added) = recorded_result!(run, answer, result, added, answer.result)
recorded_result!(run, answer, transition, added, ::Nothing) = recorded_complete!(run, answer, transition, added)
recorded_result!(run, answer, transition, added, result::Completion) = recorded_result!(run, answer, transition, added, result, getfield(result, :status))
recorded_result!(run, answer, transition, added, result) = recorded_result!(run, answer, transition, added, result, completionstatus(result.done))
recorded_result!(run, answer, transition, added, result, ::Finished) = recorded_complete!(run, answer, transition, added)
recorded_result!(run, answer, transition, added, result, ::Unfinished) = recorded_partial!(run, answer, result)
function recorded_partial!(run, answer, result)
    message_start!(run.callback, answer.message, answer.started)
    emit(run.callback, (; type=:message_end, message=deepcopy(answer.message)))
    emit(run.callback, (; type=:turn_end, message=deepcopy(answer.message), tool_results=Dict{String, Any}[]))
    recorded_incomplete!(run, result, run.agent.fault)
end

recorded_incomplete!(run, result, rejected::History.Rejected) = rejected
recorded_incomplete!(run, result, ::Nothing) = recorded_incomplete!(run, result, turnstate(run.agent))
recorded_incomplete!(run, result, ::Cancelled) = :cancelled
recorded_incomplete!(run, result, ::Union{Idle, Running}) = result

function recorded_complete!(run, answer, transition, added)
    present!(run.agent, added, run.messages, run.callback; started=answer.started)
    recorded_tools_begin!(run, answer.message, answer.result, transition, run.agent.fault)
end

recorded_tools_begin!(run, message, completion, transition, rejected::History.Rejected) = rejected
function recorded_tools_begin!(run, message, completion, transition, ::Nothing)
    results = recorded_tools!(run.agent, transition.effects, run.messages, run.callback)
    recorded_tools_done!(run, message, completion, results)
end

recorded_tools_done!(run, message, completion, result) = result
function recorded_tools_done!(run, message, completion, results::Vector)
    emit(run.callback, (; type=:turn_end, message=deepcopy(message), tool_results=deepcopy(results)))
    recorded_post_tools!(run, message, completion, run.agent.fault)
end

recorded_post_tools!(run, message, completion, rejected::History.Rejected) = rejected
recorded_post_tools!(run, message, completion, ::Nothing) = recorded_post_sync!(run, message, completion, sync!(run.agent))
recorded_post_sync!(run, message, completion, rejected::History.Rejected) = rejected
function recorded_post_sync!(run, message, completion, ::Nothing)
    result, added = transition!(revision -> Conversation.Advance(revision), run.agent)
    recorded_next!(run, message, completion, result, added)
end

recorded_next!(run, message, completion, result, added) = result
recorded_next!(run, message, completion, result::Kernel.Applied, added) = recorded_next!(run, message, completion, result, added, turnstate(run.agent))
recorded_next!(run, message, completion, result, added, ::Cancelled) = :cancelled
function recorded_next!(run, message, completion, result, added, ::Union{Idle, Running})
    isempty(result.effects) && return finish(message, completion)
    emit(run.callback, (; type=:turn_start))
    present!(run.agent, added, run.messages, run.callback)
    recorded_effect!(run, result, run.agent.fault)
end
recorded_effect!(run, result, rejected::History.Rejected) = rejected
recorded_effect!(run, result, ::Nothing) = only(result.effects)
