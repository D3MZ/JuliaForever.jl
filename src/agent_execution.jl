function submitted(agent, executor, effect, context)
    rejected = fault(agent)
    isnothing(rejected) || return rejected
    handle = try
        Execution.submit!(executor, effect, 1, context; detailed=effect.effect isa Conversation.ModelRequest, on_handle=handle -> begin
            cancel = lock(agent.lock) do
                agent.handle = handle
                agent.cancelled || !isnothing(agent.fault)
            end
            cancel && Execution.cancel!(handle)
        end)
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
    rejected = fault(agent)
    isnothing(rejected) || return rejected
    outcome.id == effect.id && outcome.attempt == 1 ? outcome : Execution.Rejected(:stale_outcome)
end

unresolved(agent::Agent, outcome::History.Rejected) = outcome
unresolved(agent::Agent, outcome) = isnothing(agent.history) ? outcome : Execution.Uncertain(outcome)

function execution_tools!(agent, executor, context, effects, messages, callback)
    results = Dict{String, Any}[]
    for effect in effects
        call = convert(Dict{String, Any}, effect.effect.call)
        toolstart(call, callback)
        rejected = fault(agent)
        isnothing(rejected) || return rejected
        outcome = cancelled(agent) ? nothing : submitted(agent, executor, effect, context)
        reply = if isnothing(outcome) || outcome isa Execution.Cancelled && cancelled(agent)
            Conversation.ToolReply(ToolFailure("Operation cancelled"))
        elseif outcome isa Execution.Completed
            outcome.value isa Conversation.ToolReply || return Execution.Rejected(:unexpected_result)
            outcome.value
        else
            return outcome
        end
        result = reply.result
        ended = (; type=:tool_execution_end, tool_call_id=call["id"], tool_name=callinfo(call).name, result, iserror=result.iserror)
        isnothing(agent.history) && emit(callback, ended)
        transition, added = transition!(revision -> Kernel.Observe(revision, effect.id, reply), agent)
        transition isa Kernel.Applied || return transition
        isnothing(agent.history) || emit(callback, ended)
        present!(agent, added, messages, callback)
        push!(results, toolmessage(call, result))
    end
    results
end

respond_execution!(::Agent, prompt, executor, context; kwargs...) = Execution.Rejected(:executor)
respond_execution!(::Agent, prompt, ::Execution.Executor, context; kwargs...) = Execution.Rejected(:context)

function finish(message, result::Execution.ModelResult{Conversation.ModelReply})
    reply = result.observation.message
    finish(message, Completion(message, result.usage, reply.finish, reply.done, result.error))
end

function respond_execution!(agent::Agent, prompt, executor::Execution.Executor, context::AbstractString; on_event, on_agent_event, parameters, tool_execution)
    rejected = fault(agent)
    isnothing(rejected) || return rejected
    isnothing(on_event) || return Execution.Rejected(:streaming)
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
            isempty(next.effects) && return Execution.Turn(finish(message, model), models)
            emit(on_agent_event, (; type=:turn_start))
            present!(agent, added, messages, on_agent_event)
            effect = only(next.effects)
        end
    finally
        try
            if isnothing(agent.history)
                if agent.state.phase in (Conversation.ReadyModel, Conversation.ReadyDecision, Conversation.WaitingModel, Conversation.WaitingTools)
                    transition!(revision -> Conversation.Interrupt(revision, "turn interrupted"), agent)
                end
                sync!(agent)
            else
                interrupted!(agent)
            end
            emit(on_agent_event, (; type=:agent_end, messages=deepcopy(messages)))
        finally
            finish!(agent)
        end
    end
end
