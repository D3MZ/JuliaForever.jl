struct ContextModel <: Kernel.Effect
    messages::Vector{Conversation.Message}
    tools::ToolChanges
end

resulttype(::Conversation.ModelRequest) = Execution.ModelResult
resulttype(::ContextModel) = Execution.ModelResult
resulttype(::Kernel.Effect) = Kernel.Observation

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

exposure(tools) = nothing
exposure(tools::ToolSet) = lock(() -> copy(tools.loaded), tools.lock)

function submitted(agent::Agent, executor, effect, context, ::Nothing)
    handle = try
        Execution.submit!(executor, effect, 1, context, resulttype(effect.effect); exposed=exposure(agent.tools), on_handle=handle -> register!(agent, handle))
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
    ended = (; type=:tool_execution_end, tool_call_id=call["id"], tool_name=callinfo(call).name, result=visible(result), iserror=result.iserror)
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

function finish(message, result::Execution.ModelResult{Conversation.ModelReply})
    reply = result.observation.message
    finish(message, Completion(message, result.usage, reply.finish, reply.status, result.error))
end

function respond_execution!(agent::Agent, prompt, executor::Execution.Executor, context::AbstractString; on_event, on_agent_event, parameters, tool_execution)
    respond_execution!(agent, prompt, executor, context, on_event, fault(agent); on_agent_event, parameters, tool_execution)
end

respond_execution!(agent::Agent, prompt, executor::Execution.Executor, context::AbstractString, on_event, rejected::History.Rejected; kwargs...) = rejected
respond_execution!(agent::Agent, prompt, executor::Execution.Executor, context::AbstractString, on_event, ::Nothing; kwargs...) = Execution.Rejected(:streaming)

function respond_execution!(agent::Agent, prompt, executor::Execution.Executor, context::AbstractString, ::Nothing, ::Nothing; on_agent_event, parameters, tool_execution)
    isempty(parameters) || return Execution.Rejected(:parameters)
    execution_mode!(agent, prompt, executor, context, toolmode(tool_execution); on_agent_event)
end
execution_mode!(agent, prompt, executor, context, mode; kwargs...) = Execution.Rejected(:parallel_tools)

execution_mode!(agent, prompt, executor, context, ::Sequential; on_agent_event) = execution_start!(agent, prompt, executor, context, startturn!(agent); on_agent_event)
execution_start!(agent, prompt, executor, context, ::Nothing; kwargs...) = :busy
function execution_start!(agent, prompt, executor, context, ::Running; on_agent_event)
    messages = Dict{String, Any}[]
    models = Execution.ModelResult[]
    event_lock = ReentrantLock()
    callback = on_agent_event
    on_agent_event = EventSink(event_lock, callback)
    run = (; agent, executor, context, messages, models, callback=on_agent_event)
    try
        precompact!(agent, on_agent_event)
        emit(on_agent_event, (; type=:agent_start))
        emit(on_agent_event, (; type=:turn_start))
        execution_input_sync!(run, prompt, sync!(agent))
    finally
        try
            interrupt!(agent, agent.history)
            emit(on_agent_event, (; type=:agent_end, messages=deepcopy(messages)))
        finally
            finish!(agent)
        end
    end
end

execution_input_sync!(run, prompt, rejected::History.Rejected) = Execution.Turn(rejected, run.models)
function execution_input_sync!(run, prompt, ::Nothing)
    result, added = transition!(revision -> Conversation.Input(revision, prompt), run.agent)
    execution_input!(run, result, added)
end

execution_input!(run, result, added) = Execution.Turn(result, run.models)
function execution_input!(run, result::Kernel.Applied, added)
    present!(run.agent, added, run.messages, run.callback)
    agent = run.agent
    execution_cancelled!(run, cancel_transition!(agent, turnstate(agent)))
end

execution_cancelled!(run, result) = Execution.Turn(result, run.models)
execution_cancelled!(run, ::Union{Nothing, Kernel.Applied}) = execution_advance_sync!(run, sync!(run.agent))
execution_advance_sync!(run, rejected::History.Rejected) = Execution.Turn(rejected, run.models)
function execution_advance_sync!(run, ::Nothing)
    result, added = transition!(revision -> Conversation.Advance(revision), run.agent)
    execution_advance!(run, result, added)
end

execution_advance!(run, result, added) = Execution.Turn(result, run.models)
function execution_advance!(run, result::Kernel.Applied, added)
    present!(run.agent, added, run.messages, run.callback)
    execution_ready!(run, result, turnstate(run.agent))
end
function execution_ready!(run, result, ::Cancelled)
    emit(run.callback, (; type=:turn_end, message=nothing, tool_results=Dict{String, Any}[]))
    Execution.Turn(:cancelled, run.models)
end
execution_ready!(run, result, ::Union{Idle, Running}) = execution_loop!(run, only(result.effects))

function execution_loop!(run, effect)
    pending = Kernel.Pending[effect]
    result = Ref{Any}()
    while !isempty(pending)
        next = execution_step!(run, pop!(pending), turnstate(run.agent))
        schedule_pending!(pending, result, next)
    end
    result[]
end

function execution_step!(run, effect, ::Cancelled)
    result, _ = transition!(revision -> Kernel.Observe(revision, effect.id, Conversation.ModelFailure("cancelled before dispatch")), run.agent)
    execution_cancel_observed!(run, result)
end
execution_cancel_observed!(run, result) = Execution.Turn(result, run.models)
function execution_cancel_observed!(run, ::Kernel.Applied)
    emit(run.callback, (; type=:turn_end, message=nothing, tool_results=Dict{String, Any}[]))
    Execution.Turn(:cancelled, run.models)
end

function execution_step!(run, effect, ::Union{Idle, Running})
    outcome = submitted(run.agent, run.executor, requesteffect(run.callback, effect, run.agent.tools), run.context)
    execution_outcome!(run, effect, outcome)
end

execution_outcome!(run, effect, outcome) = Execution.Turn(unresolved(run.agent, outcome), run.models)
execution_outcome!(run, effect, outcome::Execution.Cancelled) = execution_cancel_outcome!(run, effect, outcome, turnstate(run.agent))
execution_cancel_outcome!(run, effect, outcome, ::Union{Idle, Running}) = Execution.Turn(unresolved(run.agent, outcome), run.models)
execution_cancel_outcome!(run, effect, outcome, turn::Cancelled) = execution_step!(run, effect, turn)
execution_outcome!(run, effect, outcome::Execution.Completed) = execution_model!(run, effect, outcome.value)
execution_model!(run, effect, value) = Execution.Turn(unresolved(run.agent, Execution.Rejected(:unexpected_result)), run.models)

function execution_model!(run, effect, model::Execution.ModelResult)
    push!(run.models, model)
    execution_reply!(run, effect, model, model.observation)
end

function execution_reply!(run, effect, model, reply::Conversation.ModelFailure)
    result, _ = transition!(revision -> Kernel.Observe(revision, effect.id, reply), run.agent)
    execution_failure!(run, result, :provider_failure)
end
execution_reply!(run, effect, model, reply) = execution_error!(run, effect, model, reply, model.error)
execution_error!(run, effect, model, reply, ::Nothing) = execution_observe!(run, effect, reply)
execution_error!(run, effect, model, reply, error) = execution_error!(run, effect, model, reply, error, getfield(reply.message, :status))
execution_error!(run, effect, model, reply, error, ::Unfinished) = execution_observe!(run, effect, reply)
function execution_error!(run, effect, model, reply, error, ::Finished)
    result, _ = transition!(revision -> Kernel.Observe(revision, effect.id, Conversation.ModelFailure("provider reported an error")), run.agent)
    execution_failure!(run, result, :provider_error)
end
execution_failure!(run, result, reason) = Execution.Turn(result, run.models)
execution_failure!(run, ::Kernel.Applied, reason) = Execution.Turn(Execution.Rejected(reason), run.models)

function execution_observe!(run, effect, reply)
    result, added = transition!(revision -> Kernel.Observe(revision, effect.id, reply), run.agent)
    execution_observed!(run, reply, result, added)
end
execution_observed!(run, reply, result, added) = Execution.Turn(result, run.models)
execution_observed!(run, reply, result::Kernel.Applied, added) = execution_observed!(run, reply, result, added, getfield(reply.message, :status))
function execution_observed!(run, reply, result::Kernel.Applied, added, ::Unfinished)
    message = convert(Dict{String, Any}, reply.message)
    emit(run.callback, (; type=:message_start, message=deepcopy(message)))
    emit(run.callback, (; type=:message_end, message=deepcopy(message)))
    emit(run.callback, (; type=:turn_end, message=deepcopy(message), tool_results=Dict{String, Any}[]))
    execution_incomplete!(run, turnstate(run.agent))
end
function execution_observed!(run, reply, result::Kernel.Applied, added, ::Finished)
    message = convert(Dict{String, Any}, reply.message)
    present!(run.agent, added, run.messages, run.callback)
    results = execution_tools!(run.agent, run.executor, run.context, result.effects, run.messages, run.callback)
    execution_tools_done!(run, message, results)
end
execution_incomplete!(run, ::Cancelled) = Execution.Turn(:cancelled, run.models)
execution_incomplete!(run, ::Union{Idle, Running}) = Execution.Turn(Execution.Rejected(:incomplete_model), run.models)

execution_tools_done!(run, message, result) = Execution.Turn(unresolved(run.agent, result), run.models)
function execution_tools_done!(run, message, results::Vector)
    emit(run.callback, (; type=:turn_end, message=deepcopy(message), tool_results=deepcopy(results)))
    execution_post_sync!(run, message, sync!(run.agent))
end
execution_post_sync!(run, message, rejected::History.Rejected) = Execution.Turn(rejected, run.models)
function execution_post_sync!(run, message, ::Nothing)
    precompactnext!(run.agent, run.callback)
    result, added = transition!(revision -> Conversation.Advance(revision), run.agent)
    execution_next!(run, message, result, added)
end
execution_next!(run, message, result, added) = Execution.Turn(result, run.models)
execution_next!(run, message, result::Kernel.Applied, added) = execution_next!(run, message, result, added, turnstate(run.agent))
execution_next!(run, message, result, added, ::Cancelled) = Execution.Turn(:cancelled, run.models)
function execution_next!(run, message, result, added, ::Union{Idle, Running})
    isempty(result.effects) && return Execution.Turn(finish(message, last(run.models)), run.models)
    emit(run.callback, (; type=:turn_start))
    present!(run.agent, added, run.messages, run.callback)
    only(result.effects)
end

function interrupt!(agent::Agent, ::Nothing)
    interrupt!(agent, agent.state.phase)
    sync!(agent)
    nothing
end

interrupt!(agent::Agent, ::History.Store) = interrupted!(agent)

function finishauto!(agent, result::Execution.Turn, usage, settings::AutoCompaction, summarize, callback)
    latest = isempty(result.models) ? nothing : last(result.models).usage
    finishauto!(agent, result.value, latest, settings, summarize, callback)
end
finishauto!(agent, result::Execution.Turn, usage, settings::ChangingCompaction, summarize, callback) = finishauto!(agent, result, usage, settings.select(), summarize, callback)

requesteffect(callback, effect, tools) = effect
requesteffect(sink::EventSink, effect, tools) = lock(() -> requesteffect(sink.callback, effect, tools), sink.lock)
function requesteffect(listener::Extensions.Listener, effect::Kernel.Pending{Conversation.ModelRequest}, tools)
    isempty(get(listener.events, :context, ())) && isempty(get(listener.events, :context_with_system, ())) && return effect
    original = Dict{String, Any}[convert(Dict{String, Any}, message) for message in effect.effect.messages]
    seedtools!(original, tools)
    request = requestview(listener, effect.effect.messages, tools, nothing)
    messages = Conversation.Message[Conversation.RawMessage(message) for message in request.messages]
    baseline = toolbaseline(contexthead(original), contexthead(request.messages))
    Kernel.Pending(effect.id, ContextModel(messages, toolchanges(tools, request.tools, request.messages, baseline)))
end

initialnames(messages, role) = Set{String}()
initialnames(messages, ::ContextSystem) = Set(String(tool["name"]) for tool in get(first(messages), "toolsAdded", []))
seedworkertools!(messages, available, tools, ::ClearTools) = messages
function seedworkertools!(messages, available, tools, ::RetainTools)
    names = initialnames(messages, contexthead(messages))
    missing = OrderedDict{String, Tool}(key => value for (key, value) in pairs(available) if haskey(tools, key) && key ∉ names)
    seedtools!(messages, missing)
end

function Execution.perform(work::Execution.Work{ContextModel}, cancellation::Execution.Cancellation)
    capabilities = Execution.context(work.context)
    try
        messages = modelmessages(work.effect.messages)
        available = Execution.worktools(capabilities.tools, work.exposed)
        tools = applychanges(available, work.effect.tools)
        seedworkertools!(messages, available, tools, work.effect.tools.baseline)
        request = contextrequest(capabilities.provider, messages, currentsystem(messages), tools)
        performcontext(work, capabilities, request)
    catch
        Execution.result(Conversation.ModelFailure("provider did not return"), work.result)
    end
end

performcontext(work, capabilities, ::UnsupportedContextRequest) = Execution.result(contextfailure(), work.result)
function performcontext(work, capabilities, request::RequestView)
    parameters = deepcopy(capabilities.parameters)
    answer = withcontext(work.effect.messages) do
        isempty(parameters) ? complete(capabilities.provider, request.messages, request.tools) : complete(capabilities.provider, request.messages, request.tools; parameters)
    end
    Execution.result(price(capabilities.provider, answer), work.result)
end
