detailed(::Conversation.ModelRequest) = true
detailed(::Kernel.Effect) = false

function register!(agent::Agent, handle::Execution.Handle)
    turn, failure = lock(agent.lock) do
        agent.handle = handle
        agent.turn, agent.fault
    end
    register!(handle, turn, failure)
end

register!(handle::Execution.Handle, ::Union{Idle, Running}, ::Nothing) = nothing
register!(handle::Execution.Handle, ::Union{Idle, Running}, ::History.Rejected) = Execution.cancel!(handle)
register!(handle::Execution.Handle, ::Cancelled, failure) = Execution.cancel!(handle)

submitted(agent::Agent, executor, effect, context) = submitted(agent, executor, effect, context, fault(agent))
submitted(agent::Agent, executor, effect, context, rejected::History.Rejected) = rejected
submitted(agent::Agent, executor, effect, context, ::Cancelled) = nothing
submitted(agent::Agent, executor, effect, context, ::Union{Idle, Running}) = submitted(agent, executor, effect, context)

function submitted(agent::Agent, executor, effect, context, ::Nothing)
    handle = try
        Execution.submit!(executor, effect, 1, context; detailed=detailed(effect.effect), on_handle=handle -> register!(agent, handle))
    catch
        lock(agent.lock) do
            agent.handle = nothing
        end
        return Execution.Rejected(:submission)
    end
    outcome = try
        fetch(handle)
    finally
        lock(agent.lock) do
            agent.handle = nothing
        end
    end
    submitted(outcome, effect, fault(agent))
end

submitted(outcome, effect, rejected::History.Rejected) = rejected

function submitted(outcome, effect, ::Nothing)
    outcome.id == effect.id && outcome.attempt == 1 ? outcome : Execution.Rejected(:stale_outcome)
end

unresolved(agent::Agent, outcome::History.Rejected) = outcome
unresolved(agent::Agent, outcome) = unresolved(agent.history, outcome)
unresolved(::Nothing, outcome) = outcome
unresolved(::History.Store, outcome) = Execution.Uncertain(outcome)

toolreply(::Nothing, ::TurnState) = Conversation.ToolReply(ToolFailure("Operation cancelled"))
toolreply(outcome::Execution.Cancelled, ::Cancelled) = Conversation.ToolReply(ToolFailure("Operation cancelled"))
toolreply(outcome::Execution.Completed, ::TurnState) = toolreply(outcome.value)
toolreply(reply::Conversation.ToolReply) = reply
toolreply(value) = Execution.Rejected(:unexpected_result)
toolreply(outcome, ::TurnState) = outcome

function execution_tools!(agent, executor, context, effects, messages, callback)
    foldl(effects; init=Dict{String, Any}[]) do results, effect
        execution_tool!(agent, executor, context, effect, messages, callback, results)
    end
end

execution_tool!(agent, executor, context, effect, messages, callback, outcome) = outcome

function execution_tool!(agent, executor, context, effect, messages, callback, results::Vector{Dict{String, Any}})
    call = convert(Dict{String, Any}, effect.effect.call)
    toolstart(call, callback)
    execution_tool!(agent, executor, context, effect, messages, callback, results, call, fault(agent))
end

execution_tool!(agent, executor, context, effect, messages, callback, results, call, rejected::History.Rejected) = rejected

function execution_tool!(agent, executor, context, effect, messages, callback, results, call, ::Nothing)
    turn = lock(() -> agent.turn, agent.lock)
    outcome = submitted(agent, executor, effect, context, turn)
    turn = lock(() -> agent.turn, agent.lock)
    observe_tool!(agent, effect, messages, callback, results, call, toolreply(outcome, turn))
end

observe_tool!(agent, effect, messages, callback, results, call, outcome) = outcome
before_tool!(callback, ended, ::Nothing) = emit(callback, ended)
before_tool!(callback, ended, ::History.Store) = nothing
after_tool!(callback, ended, ::Nothing) = nothing
after_tool!(callback, ended, ::History.Store) = emit(callback, ended)

function observe_tool!(agent, effect, messages, callback, results, call, reply::Conversation.ToolReply)
    result = reply.result
    ended = (; type=:tool_execution_end, tool_call_id=call["id"], tool_name=callinfo(call).name, result, iserror=result.iserror)
    before_tool!(callback, ended, agent.history)
    transition, added = transition!(revision -> Kernel.Observe(revision, effect.id, reply), agent)
    finish_tool!(agent, messages, callback, results, call, result, ended, transition, added)
end

finish_tool!(agent, messages, callback, results, call, result, ended, transition, added) = transition

function finish_tool!(agent, messages, callback, results, call, result, ended, transition::Kernel.Applied, added)
    after_tool!(callback, ended, agent.history)
    present!(agent, added, messages, callback)
    push!(results, toolmessage(call, result))
end

respond_execution!(::Agent, prompt, executor, context; kwargs...) = Execution.Rejected(:executor)
respond_execution!(::Agent, prompt, ::Execution.Executor, context; kwargs...) = Execution.Rejected(:context)

function respond_execution!(agent::Agent, prompt, executor::Execution.Executor, context::AbstractString; on_event, on_agent_event, parameters, tool_execution)
    respond_execution!(agent, prompt, executor, context, on_event, fault(agent); on_agent_event, parameters, tool_execution)
end

respond_execution!(agent::Agent, prompt, executor::Execution.Executor, context::AbstractString, on_event, rejected::History.Rejected; kwargs...) = rejected
respond_execution!(agent::Agent, prompt, executor::Execution.Executor, context::AbstractString, on_event, ::Nothing; kwargs...) = Execution.Rejected(:streaming)

function respond_execution!(agent::Agent, prompt, executor::Execution.Executor, context::AbstractString, ::Nothing, ::Nothing; on_agent_event, parameters, tool_execution)
    isempty(parameters) || return Execution.Rejected(:parameters)
    tool_execution == :sequential || return Execution.Rejected(:parallel_tools)
    begin!(agent) || return :busy
    messages = Dict{String, Any}[]
    models = Execution.ModelResult[]
    event_lock = ReentrantLock()
    callback = on_agent_event
    on_agent_event = event -> lock(() -> emit(callback, event), event_lock)
    try
        emit(on_agent_event, (; type=:agent_start))
        emit(on_agent_event, (; type=:turn_start))
        synced = sync!(agent)
        synced isa History.Rejected && return Execution.Turn(synced, models)
        next, added = transition!(revision -> Conversation.Input(revision, prompt), agent)
        next isa Kernel.Applied || return Execution.Turn(next, models)
        present!(agent, added, messages, on_agent_event)
        if cancelled(agent) && !agent.state.cancelled
            next, _ = transition!(revision -> Conversation.Cancel(revision), agent)
            next isa Kernel.Applied || return Execution.Turn(next, models)
        end
        synced = sync!(agent)
        synced isa History.Rejected && return Execution.Turn(synced, models)
        next, added = transition!(revision -> Conversation.Advance(revision), agent)
        next isa Kernel.Applied || return Execution.Turn(next, models)
        present!(agent, added, messages, on_agent_event)
        if cancelled(agent)
            emit(on_agent_event, (; type=:turn_end, message=nothing, tool_results=Dict{String, Any}[]))
            return Execution.Turn(:cancelled, models)
        end
        effect = only(next.effects)
        while true
            if cancelled(agent)
                observed, _ = transition!(revision -> Kernel.Observe(revision, effect.id, Conversation.ModelFailure("cancelled before dispatch")), agent)
                observed isa Kernel.Applied || return Execution.Turn(observed, models)
                emit(on_agent_event, (; type=:turn_end, message=nothing, tool_results=Dict{String, Any}[]))
                return Execution.Turn(:cancelled, models)
            end
            outcome = submitted(agent, executor, effect, context)
            if outcome isa Execution.Cancelled && cancelled(agent)
                observed, _ = transition!(revision -> Kernel.Observe(revision, effect.id, Conversation.ModelFailure("cancelled before dispatch")), agent)
                observed isa Kernel.Applied || return Execution.Turn(observed, models)
                emit(on_agent_event, (; type=:turn_end, message=nothing, tool_results=Dict{String, Any}[]))
                return Execution.Turn(:cancelled, models)
            end
            outcome isa Execution.Completed || return Execution.Turn(unresolved(agent, outcome), models)
            outcome.value isa Execution.ModelResult || return Execution.Turn(unresolved(agent, Execution.Rejected(:unexpected_result)), models)
            model = outcome.value
            push!(models, model)
            reply = model.observation
            if reply isa Conversation.ModelFailure
                observed, _ = transition!(revision -> Kernel.Observe(revision, effect.id, reply), agent)
                observed isa Kernel.Applied || return Execution.Turn(observed, models)
                return Execution.Turn(Execution.Rejected(:provider_failure), models)
            end
            if !isnothing(model.error) && reply.message.done
                observed, _ = transition!(revision -> Kernel.Observe(revision, effect.id, Conversation.ModelFailure("provider reported an error")), agent)
                observed isa Kernel.Applied || return Execution.Turn(observed, models)
                return Execution.Turn(Execution.Rejected(:provider_error), models)
            end
            transition, added = transition!(revision -> Kernel.Observe(revision, effect.id, reply), agent)
            transition isa Kernel.Applied || return Execution.Turn(transition, models)
            message = convert(Dict{String, Any}, reply.message)
            if !reply.message.done
                emit(on_agent_event, (; type=:message_start, message=deepcopy(message)))
                emit(on_agent_event, (; type=:message_end, message=deepcopy(message)))
                emit(on_agent_event, (; type=:turn_end, message=deepcopy(message), tool_results=Dict{String, Any}[]))
                return Execution.Turn(cancelled(agent) ? :cancelled : Execution.Rejected(:incomplete_model), models)
            end
            present!(agent, added, messages, on_agent_event)
            results = execution_tools!(agent, executor, context, transition.effects, messages, on_agent_event)
            results isa Vector || return Execution.Turn(unresolved(agent, results), models)
            emit(on_agent_event, (; type=:turn_end, message=deepcopy(message), tool_results=deepcopy(results)))
            synced = sync!(agent)
            synced isa History.Rejected && return Execution.Turn(synced, models)
            next, added = transition!(revision -> Conversation.Advance(revision), agent)
            next isa Kernel.Applied || return Execution.Turn(next, models)
            cancelled(agent) && return Execution.Turn(:cancelled, models)
            isempty(next.effects) && return Execution.Turn(message["content"], models)
            emit(on_agent_event, (; type=:turn_start))
            present!(agent, added, messages, on_agent_event)
            effect = only(next.effects)
        end
    finally
        try
            interrupt!(agent, agent.history)
            emit(on_agent_event, (; type=:agent_end, messages=deepcopy(messages)))
        finally
            finish!(agent)
        end
    end
end

function interrupt!(agent::Agent, ::Nothing)
    interrupt!(agent, agent.state.phase)
    sync!(agent)
    nothing
end

interrupt!(agent::Agent, ::History.Store) = interrupted!(agent)
