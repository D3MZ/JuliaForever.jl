function openagent(provider, tools, messages, initial, ::Nothing)
    Agent(provider, tools, messages, initial, initial, Kernel.Event[], ReentrantLock(), false, nothing, ShellCancellation(), nothing, nothing, 0, nothing)
end

function openagent(provider, tools, messages, initial, history::History.Store)
    snapshot = History.snapshot(history)
    snapshot isa History.Rejected && return snapshot
    if snapshot.revision == 0
        record = History.encode_initial(initial)
        record isa History.Rejected && return record
        revision = History.append!(history, 0, Any[record])
        revision isa History.Rejected && return revision
        return Agent(provider, tools, messages, initial, initial, Kernel.Event[], ReentrantLock(), false, nothing, ShellCancellation(), nothing, history, revision, nothing)
    end
    isempty(messages) || return History.Rejected(:history_exists)
    batches = snapshot.batches
    length(batches) == snapshot.revision || return History.Rejected(:invalid_record)
    all(batch -> length(batch) == 1, batches) || return History.Rejected(:invalid_record)
    initial = History.decode_initial(only(first(batches)))
    initial isa History.Rejected && return initial
    initial.automatic && return History.Rejected(:invalid_record)
    state = initial
    events = Kernel.Event[]
    for batch in batches[2:end]
        event = History.decode_event(only(batch))
        event isa History.Rejected && return event
        result = Kernel.step(state, event)
        result isa Kernel.Applied || return History.Rejected(:invalid_record)
        state = result.state
        push!(events, event)
    end
    messages = Dict{String, Any}[convert(Dict{String, Any}, message) for message in state.messages]
    fault = if !isempty(state.kernel.pending)
        History.Rejected(:uncertain_effect)
    elseif state.phase in (Conversation.ReadyModel, Conversation.ReadyDecision, Conversation.WaitingModel, Conversation.WaitingTools)
        History.Rejected(:incomplete_turn)
    else
        nothing
    end
    Agent(provider, tools, messages, initial, state, events, ReentrantLock(), false, nothing, ShellCancellation(), nothing, history, snapshot.revision, fault)
end

persist!(agent::Agent, event) = persist!(agent, agent.history, event)
persist!(agent::Agent, ::Nothing, event) = nothing

function persist!(agent::Agent, history::History.Store, event)
    complete = false
    try
        record = History.encode(event)
        result = record isa History.Rejected ? record : History.append!(history, agent.history_revision, Any[record])
        complete = true
        if result isa History.Rejected
            agent.fault = result
            return result
        end
        agent.history_revision = result
        nothing
    finally
        complete || (agent.fault = History.Rejected(:uncertain))
    end
end

fault(agent::Agent) = lock(() -> agent.fault, agent.lock)

function interrupted!(agent::Agent)
    lock(agent.lock) do
        if isnothing(agent.fault)
            if !isempty(agent.state.kernel.pending)
                agent.fault = History.Rejected(:uncertain_effect)
            elseif agent.state.phase in (Conversation.ReadyModel, Conversation.ReadyDecision, Conversation.WaitingModel, Conversation.WaitingTools)
                agent.fault = History.Rejected(:incomplete_turn)
            end
        end
    end
end

"Record an explicit decision to abandon an interrupted or uncertain turn; this does not undo external effects."
function abandon!(agent::Agent, reason::AbstractString)
    lock(agent.lock) do
        agent.running && return History.Rejected(:busy)
        isnothing(agent.history) && return History.Rejected(:no_history)
        isnothing(agent.fault) && return History.Rejected(:not_interrupted)
        agent.fault.reason in (:uncertain_effect, :incomplete_turn) || return agent.fault
        event = Conversation.Abandon(agent.state.revision, String(reason))
        result = Kernel.step(agent.state, event)
        result isa Kernel.Applied || return History.Rejected(result.reason)
        agent.fault = nothing
        saved = persist!(agent, event)
        if saved isa History.Rejected
            agent.fault = saved
            return saved
        end
        agent.state = result.state
        push!(getfield(agent, :events), event)
        empty!(agent.messages)
        append!(agent.messages, [convert(Dict{String, Any}, message) for message in result.state.messages])
        result
    end
end

function recorded_tools!(agent, effects, messages, callback)
    results = Dict{String, Any}[]
    for effect in effects
        call = convert(Dict{String, Any}, effect.effect.call)
        toolstart(call, callback)
        !isnothing(agent.fault) && return agent.fault
        result = toolresult(agent, call, effect.effect, callback)
        !isnothing(agent.fault) && return agent.fault
        transition, added = transition!(revision -> Kernel.Observe(revision, effect.id, Conversation.ToolReply(result)), agent)
        transition isa Kernel.Applied || return transition
        present!(agent, added, messages, callback)
        !isnothing(agent.fault) && return agent.fault
        push!(results, toolmessage(call, result))
    end
    results
end

function respond_recorded!(agent::Agent, prompt; on_event=nothing, on_agent_event=nothing, parameters=Dict(), tool_execution=:sequential)
    !isnothing(agent.fault) && return agent.fault
    tool_execution == :sequential || return History.Rejected(:unsupported_execution)
    begin!(agent) || return :busy
    messages = Dict{String, Any}[]
    event_lock = ReentrantLock()
    callback = on_agent_event
    on_agent_event = event -> lock(() -> emit(callback, event), event_lock)
    try
        emit(on_agent_event, (; type=:agent_start))
        emit(on_agent_event, (; type=:turn_start))
        !isnothing(agent.fault) && return agent.fault
        synced = sync!(agent)
        synced isa History.Rejected && return synced
        next, added = transition!(revision -> Conversation.Input(revision, prompt), agent)
        next isa Kernel.Applied || return next
        present!(agent, added, messages, on_agent_event)
        !isnothing(agent.fault) && return agent.fault
        if cancelled(agent) && !agent.state.cancelled
            next, _ = transition!(revision -> Conversation.Cancel(revision), agent)
            next isa Kernel.Applied || return next
        end
        synced = sync!(agent)
        synced isa History.Rejected && return synced
        next, added = transition!(revision -> Conversation.Advance(revision), agent)
        next isa Kernel.Applied || return next
        present!(agent, added, messages, on_agent_event)
        !isnothing(agent.fault) && return agent.fault
        if cancelled(agent)
            emit(on_agent_event, (; type=:turn_end, message=nothing, tool_results=Dict{String, Any}[]))
            return :cancelled
        end
        effect = only(next.effects)
        while true
            if cancelled(agent)
                next, _ = transition!(revision -> Kernel.Observe(revision, effect.id, Conversation.ModelFailure("cancelled before dispatch")), agent)
                next isa Kernel.Applied || return next
                emit(on_agent_event, (; type=:turn_end, message=nothing, tool_results=Dict{String, Any}[]))
                return :cancelled
            end
            request = [convert(Dict{String, Any}, message) for message in effect.effect.messages]
            answer = response(agent, request, parameters, on_event, on_agent_event)
            !isnothing(agent.fault) && return agent.fault
            result = answer.result
            outcome = conversation_reply(answer)
            transition, added = transition!(revision -> Kernel.Observe(revision, effect.id, outcome), agent)
            transition isa Kernel.Applied || return transition
            if !isnothing(result) && !result.done
                answer.started || emit(on_agent_event, (; type=:message_start, message=deepcopy(answer.message)))
                emit(on_agent_event, (; type=:message_end, message=deepcopy(answer.message)))
                emit(on_agent_event, (; type=:turn_end, message=deepcopy(answer.message), tool_results=Dict{String, Any}[]))
                !isnothing(agent.fault) && return agent.fault
                return cancelled(agent) ? :cancelled : result
            end
            message = answer.message
            present!(agent, added, messages, on_agent_event; started=answer.started)
            !isnothing(agent.fault) && return agent.fault
            results = recorded_tools!(agent, transition.effects, messages, on_agent_event)
            results isa Vector || return results
            emit(on_agent_event, (; type=:turn_end, message=deepcopy(message), tool_results=deepcopy(results)))
            !isnothing(agent.fault) && return agent.fault
            synced = sync!(agent)
            synced isa History.Rejected && return synced
            next, added = transition!(revision -> Conversation.Advance(revision), agent)
            next isa Kernel.Applied || return next
            cancelled(agent) && return :cancelled
            isempty(next.effects) && return message["content"]
            emit(on_agent_event, (; type=:turn_start))
            present!(agent, added, messages, on_agent_event)
            !isnothing(agent.fault) && return agent.fault
            effect = only(next.effects)
        end
    finally
        try
            interrupted!(agent)
            emit(on_agent_event, (; type=:agent_end, messages=deepcopy(messages)))
        finally
            finish!(agent)
        end
    end
end
