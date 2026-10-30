export steer!, followup!, dequeue!, cancel!, abandon!

struct Truncated
    completion::Completion
end

abstract type TurnState end
struct Idle <: TurnState end
struct Running <: TurnState end
struct Cancelled <: TurnState end

abstract type ToolMode end
struct Sequential <: ToolMode end
struct Parallel <: ToolMode end
const toolmodes = Dict(:sequential => Sequential(), :parallel => Parallel())
toolmode(mode) = get(toolmodes, mode, nothing)

mutable struct Agent{P}
    provider::P
    tools::Dict{String, Tool}
    messages::Vector{Dict{String, Any}}
    initial::Conversation.State
    state::Conversation.State
    events::Vector{Kernel.Event}
    lock::ReentrantLock
    turn::TurnState
    shell::ShellCancellation
    handle::Any
    history::Union{Nothing, History.Store}
    history_revision::Int
    fault::Union{Nothing, History.Rejected}
end

function Agent(provider, tools, messages; history=nothing)
    transcript = Conversation.Message[Conversation.RawMessage(deepcopy(message)) for message in messages]
    initial = Conversation.State("agent-" * randstring(16); automatic=false, messages=transcript)
    openagent(provider, tools, messages, initial, history)
end

Agent(provider, tools; history=nothing) = Agent(provider, Dict{String, Tool}(name(tool) => tool for tool in tools), Dict{String, Any}[]; history)

function Base.getproperty(agent::Agent, name::Symbol)
    name === :running && return running(getfield(agent, :turn))
    name === :cancelled && return cancelled(getfield(agent, :turn))
    value = getfield(agent, name)
    name === :events ? deepcopy(value) : value
end

Base.propertynames(agent::Agent, private::Bool=false) = (fieldnames(typeof(agent))..., :running, :cancelled)

function transition!(f, agent::Agent)
    lock(agent.lock) do
        transition!(f, agent, agent.fault)
    end
end

transition!(f, agent::Agent, fault::History.Rejected) = (fault, Conversation.Message[])

function transition!(f, agent::Agent, ::Nothing)
    event = f(agent.state.revision)
    before = length(agent.state.messages)
    transition!(agent, event, before, Kernel.step(agent.state, event))
end

transition!(agent::Agent, event, before, result) = (result, Conversation.Message[])

function transition!(agent::Agent, event, before, result::Kernel.Applied)
    saved = deepcopy(event)
    transition!(agent, saved, before, result, persist!(agent, saved))
end

transition!(agent::Agent, event, before, result, rejected::History.Rejected) = (rejected, Conversation.Message[])

function transition!(agent::Agent, event, before, result::Kernel.Applied, ::Nothing)
    agent.state = result.state
    push!(getfield(agent, :events), event)
    result, result.state.messages[before+1:end]
end

outcome(result::History.Rejected, fallback) = result
outcome(result, fallback) = fallback

"Queue a user message for the next turn; steering is consumed one message at a time."
function steer!(agent::Agent, prompt)
    result, _ = transition!(revision -> Conversation.Steer(revision, prompt), agent)
    outcome(result, nothing)
end

"Queue a user message for when the agent would otherwise stop."
function followup!(agent::Agent, prompt)
    result, _ = transition!(revision -> Conversation.Followup(revision, prompt), agent)
    outcome(result, nothing)
end

"Clear and return queued steering and follow-up messages."
function dequeue!(agent::Agent)
    lock(agent.lock) do
        queued = (; steering=agent.state.steering, followups=agent.state.followups)
        dequeue!(agent, queued, agent.fault)
    end
end

dequeue!(agent::Agent, queued, fault::History.Rejected) = fault
function dequeue!(agent::Agent, queued, ::Nothing)
    isempty(queued.steering) && isempty(queued.followups) && return queued
    result, _ = transition!(revision -> Conversation.Dequeue(revision), agent)
    outcome(result, queued)
end

"Cancel native provider requests and in-flight Unix shell calls; other work stops at the next boundary."
function cancel!(agent::Agent)
    handle = nothing
    shell = nothing
    try
        lock(agent.lock) do
            cancel!(agent, agent.turn) do currenthandle, currentshell
                handle = currenthandle
                shell = currentshell
            end
        end
    finally
        cancel!(shell)
        cancelhandle!(handle)
    end
end

cancelhandle!(handle) = Execution.cancel!(handle)
cancelhandle!(context::HTTP.RequestContext) = HTTP.cancel!(context)

cancel!(f, agent::Agent, ::Idle) = false

function cancel!(f, agent::Agent, ::Union{Running, Cancelled})
    try
        result, _ = transition!(revision -> Conversation.Cancel(revision), agent)
        outcome(result, true)
    finally
        agent.turn = Cancelled()
        f(agent.handle, agent.shell)
    end
end

running(::Idle) = false
running(::Union{Running, Cancelled}) = true
cancelled(::Union{Idle, Running}) = false
cancelled(::Cancelled) = true
cancelled(agent::Agent) = lock(() -> cancelled(agent.turn), agent.lock)

function begin!(agent::Agent)
    lock(agent.lock) do
        begin!(agent, agent.turn)
    end
end

begin!(agent::Agent, ::Union{Running, Cancelled}) = false

function begin!(agent::Agent, ::Idle)
    agent.turn = Running()
    agent.shell = ShellCancellation()
    true
end

text(value::AbstractString) = String(value)
text(value) = nothing

function Base.convert(::Type{Conversation.ToolCall}, call::AbstractDict)
    info = callinfo(call)
    Conversation.ToolCall(String(call["id"]), text(info.name), text(info.args); metadata=call)
end

function Base.convert(::Type{Dict{String, Any}}, message::Conversation.User)
    Dict{String, Any}("role" => "user", "content" => message.content)
end

function Base.convert(::Type{Dict{String, Any}}, message::Conversation.Assistant)
    value = deepcopy(message.metadata)
    value["role"] = "assistant"
    value["content"] = message.content
    if !isempty(message.calls)
        value["tool_calls"] = [convert(Dict{String, Any}, call) for call in message.calls]
    end
    value
end

function Base.convert(::Type{Dict{String, Any}}, call::Conversation.ToolCall)
    isempty(call.metadata) || return deepcopy(call.metadata)
    Dict{String, Any}("id" => call.id, "type" => "function", "function" => Dict("name" => call.name, "arguments" => call.arguments))
end

function Base.convert(::Type{Dict{String, Any}}, message::Conversation.ToolMessage)
    value = Dict{String, Any}("role" => "tool", "tool_call_id" => message.id, "content" => message.content, "is_error" => message.iserror)
    attach!(value, message.image)
end

attach!(value, ::Nothing) = value

function attach!(value, image::Image)
    value["image"] = Dict("mime" => image.mime, "data" => image.data)
    value
end

Base.convert(::Type{Dict{String, Any}}, message::Conversation.RawMessage) = deepcopy(message.value)

function sync!(agent::Agent)
    result = lock(agent.lock) do
        recorded = [convert(Dict{String, Any}, message) for message in agent.state.messages]
        if !Kernel.same(recorded, agent.messages)
            history = Conversation.Message[Conversation.RawMessage(deepcopy(message)) for message in agent.messages]
            result, _ = transition!(revision -> Conversation.History(revision, history), agent)
            return outcome(result, nothing)
        end
        nothing
    end
    result
end

function finish!(agent::Agent)
    lock(agent.lock) do
        agent.turn = Idle()
    end
end

name(::Read) = "read"
name(::Write) = "write"
name(::Edit) = "edit"

schema(::Read) = Dict("type" => "object", "properties" => Dict("path" => Dict("type" => "string"), "offset" => Dict("type" => "integer"), "limit" => Dict("type" => "integer")), "required" => ["path"])
schema(::Write) = Dict("type" => "object", "properties" => Dict("path" => Dict("type" => "string"), "content" => Dict("type" => "string")), "required" => ["path", "content"])
schema(::Edit) = Dict("type" => "object", "properties" => Dict("path" => Dict("type" => "string"), "edits" => Dict("type" => "array", "items" => Dict("type" => "object", "properties" => Dict("oldText" => Dict("type" => "string"), "newText" => Dict("type" => "string")), "required" => ["oldText", "newText"]))), "required" => ["path", "edits"])

description(::Read) = "Read a text file or a PNG/JPEG image up to 10 MiB. Offset and limit are line based for text."
description(::Write) = "Create or overwrite a text file."
description(::Edit) = "Replace unique, non-overlapping text in a file."

definition(tool) = Dict("type" => "function", "function" => Dict("name" => name(tool), "description" => description(tool), "parameters" => schema(tool)))

invoke(tool::Tool, args, ::ShellCancellation) = execute(tool, args)
invoke(tool::Union{Bash, PowerShell}, args, cancel::ShellCancellation) = Sys.iswindows() ? execute(tool, args) : execute(tool, args; cancel)

function invoke(agent, call)
    tool, args = try
        tool = call["function"]
        agent.tools[tool["name"]], JSON3.read(tool["arguments"])
    catch exception
        return ToolFailure(sprint(showerror, exception))
    end
    attempt(() -> invoke(tool, args, agent.shell))
end

emit(::Nothing, event) = nothing
emit(callback, event) = callback(event)

abstract type MessagePresentation end
struct Unannounced <: MessagePresentation end
struct Announced <: MessagePresentation end

message_start!(callback, message, ::Unannounced) = emit(callback, (; type=:message_start, message=deepcopy(message)))
message_start!(callback, message, ::Announced) = nothing

function record!(agent, message, messages, on_agent_event; started=Unannounced())
    message_start!(on_agent_event, message, started)
    push!(agent.messages, message)
    push!(messages, message)
    emit(on_agent_event, (; type=:message_end, message=deepcopy(message)))
end

function present!(agent, added, messages, on_agent_event; started=Unannounced())
    for (index, message) in enumerate(added)
        record!(agent, convert(Dict{String, Any}, message), messages, on_agent_event; started=index == 1 ? started : Unannounced())
    end
end

abstract type AgentUpdate end
struct AgentText <: AgentUpdate
    event
end
struct AgentThinking <: AgentUpdate
    event
end
struct AgentToolCall <: AgentUpdate
    event
end

const agentupdates = Dict(:text => AgentText, :thinking => AgentThinking, :tool_call => AgentToolCall)
agentupdate(event) = agentupdate(get(agentupdates, event.type, Nothing), event)
agentupdate(::Type{Nothing}, event) = nothing
agentupdate(::Type{T}, event) where {T <: AgentUpdate} = T(event)

function update!(partial, calls, update::AgentText)
    event = update.event
    partial["content"] = appendtext(partial["content"], event.text)
end

function update!(partial, calls, update::AgentThinking)
    event = update.event
    partial["reasoning_content"] = get(partial, "reasoning_content", "") * event.text
end

function update!(partial, calls, update::AgentToolCall)
    event = update.event
    if !haskey(calls, event.index)
        calls[event.index] = Dict("id" => "", "type" => "function", "function" => Dict("name" => "", "arguments" => ""))
        push!(get!(partial, "tool_calls", []), calls[event.index])
    end
    call = calls[event.index]
    writeonce!(call, "id", event.id)
    writeonce!(call["function"], "name", event.name)
    call["function"]["arguments"] *= event.arguments
end

publish!(partial, calls, started, on_agent_event, ::Nothing) = nothing

publish!(partial, calls, started, on_agent_event, update::AgentUpdate) = publish!(partial, calls, started, on_agent_event, update, started[])
function publish!(partial, calls, started, on_agent_event, update::AgentUpdate, ::Unannounced)
    message_start!(on_agent_event, partial, Unannounced())
    started[] = Announced()
    publish!(partial, calls, started, on_agent_event, update, Announced())
end
function publish!(partial, calls, started, on_agent_event, update::AgentUpdate, ::Announced)
    update!(partial, calls, update)
    emit(on_agent_event, (; type=:message_update, assistant_event=update.event, message=deepcopy(partial)))
end

response(message::Completion) = (; message=message.message, result=message, started=Unannounced())
response(message) = (; message, result=nothing, started=Unannounced())

register!(agent::Agent, ::Nothing) = nothing

function register!(agent::Agent, context::HTTP.RequestContext)
    turn, failure = lock(agent.lock) do
        agent.handle = context
        agent.turn, agent.fault
    end
    register!(context, turn, failure)
end

register!(context::HTTP.RequestContext, ::Union{Idle, Running}, ::Nothing) = nothing
register!(context::HTTP.RequestContext, ::Union{Idle, Running}, ::History.Rejected) = HTTP.cancel!(context)
register!(context::HTTP.RequestContext, ::Cancelled, failure) = HTTP.cancel!(context)
unregister!(agent::Agent, ::Nothing) = nothing
unregister!(agent::Agent, context::HTTP.RequestContext) = lock(() -> (agent.handle = nothing), agent.lock)

requestcancelled(::HTTP.CanceledError, ::Cancelled) = true
requestcancelled(exception, turn) = false

function request!(f, agent::Agent, partial, started)
    context = requestcontext(agent.provider)
    register!(agent, context)
    depth = length(current_exceptions())
    try
        task_local_storage(f, requestkey, context)
    finally
        unregister!(agent, context)
        exceptions = current_exceptions()
        if length(exceptions) > depth && requestcancelled(last(exceptions).exception, turnstate(agent))
            result = Completion(deepcopy(partial), nothing, "cancelled", false, "cancelled")
            return (; message=result.message, result, started=started[])
        end
    end
end

function response(agent, messages, parameters, ::Nothing, on_agent_event)
    partial = Dict{String, Any}("role" => "assistant", "content" => nothing)
    request!(agent, partial, Ref{MessagePresentation}(Unannounced())) do
        message = isempty(parameters) ? complete(agent.provider, messages, agent.tools) : complete(agent.provider, messages, agent.tools; parameters)
        response(message)
    end
end

function response(agent, messages, parameters, on_event, on_agent_event)
    partial = Dict{String, Any}("role" => "assistant", "content" => nothing)
    calls = Dict{Any, Any}()
    started = Ref{MessagePresentation}(Unannounced())
    callback = event -> begin
        on_event(event)
        publish!(partial, calls, started, on_agent_event, agentupdate(event))
    end
    request!(agent, partial, started) do
        result = stream(agent.provider, messages, agent.tools; parameters, on_event=callback)
        (; message=result.message, result, started=started[])
    end
end

function callinfo(call)
    try
        fn = call["function"]
        (; name=get(fn, "name", nothing), args=get(fn, "arguments", nothing))
    catch
        (; name=nothing, args=nothing)
    end
end

function toolstart(call, on_agent_event)
    info = callinfo(call)
    emit(on_agent_event, (; type=:tool_execution_start, tool_call_id=call["id"], tool_name=info.name, args=info.args))
end

invoke(agent, call, ::Conversation.ToolRequest, ::Union{Idle, Running}) = invoke(agent, call)
invoke(agent, call, ::Conversation.SkipRequest, ::Union{Idle, Running}) = ToolFailure("Tool call \"$(callinfo(call).name)\" was not executed: the response hit the output token limit, so its arguments may be truncated. Re-issue the tool call with complete arguments.")
invoke(agent, call, ::Union{Conversation.ToolRequest, Conversation.SkipRequest}, ::Cancelled) = ToolFailure("Operation cancelled")

function toolresult(agent, call, request, on_agent_event)
    info = callinfo(call)
    id = call["id"]
    turn = lock(() -> agent.turn, agent.lock)
    result = invoke(agent, call, request, turn)
    emit(on_agent_event, (; type=:tool_execution_end, tool_call_id=id, tool_name=info.name, result, iserror=result.iserror))
    result
end

toolmessage(call, result::ToolResult) = convert(Dict{String, Any}, Conversation.ToolMessage(call["id"], content(result), result.iserror, result.image))

function toolobserve!(agent, effect, result, messages, on_agent_event)
    transition, added = transition!(revision -> Kernel.Observe(revision, effect.id, Conversation.ToolReply(result)), agent)
    present!(agent, added, messages, on_agent_event)
    transition
end

parallel(::Conversation.ToolRequest) = true
parallel(effect) = false

runtools!(agent, effects, messages, on_agent_event; tool_execution=:sequential) = runtools!(agent, effects, messages, on_agent_event, toolmode(tool_execution))

function runtools!(agent, effects, messages, on_agent_event, ::Union{Sequential, Nothing})
    results = Dict{String, Any}[]
    calls = [convert(Dict{String, Any}, effect.effect.call) for effect in effects]
    for (effect, call) in zip(effects, calls)
        toolstart(call, on_agent_event)
        result = toolresult(agent, call, effect.effect, on_agent_event)
        toolobserve!(agent, effect, result, messages, on_agent_event)
        push!(results, toolmessage(call, result))
    end
    results
end

function runtools!(agent, effects, messages, on_agent_event, ::Parallel)
    all(effect -> parallel(effect.effect), effects) || return runtools!(agent, effects, messages, on_agent_event, Sequential())
    calls = [convert(Dict{String, Any}, effect.effect.call) for effect in effects]
    foreach(call -> toolstart(call, on_agent_event), calls)
    completed = Vector{ToolResult}(undef, length(calls))
    @sync for i in eachindex(calls)
        Threads.@spawn completed[i] = toolresult(agent, calls[i], effects[i].effect, on_agent_event)
    end
    results = Dict{String, Any}[]
    for i in eachindex(calls)
        toolobserve!(agent, effects[i], completed[i], messages, on_agent_event)
        push!(results, toolmessage(calls[i], completed[i]))
    end
    results
end

function conversation_reply(answer)
    message = answer.message
    calls = Conversation.ToolCall[convert(Conversation.ToolCall, call) for call in get(message, "tool_calls", [])]
    conversation_reply(message, calls, answer.result)
end

conversation_reply(message, calls, ::Nothing) = Conversation.ModelReply(Conversation.Assistant(get(message, "content", nothing), calls, nothing, true; metadata=message))
conversation_reply(message, calls, result::Completion) = Conversation.ModelReply(Conversation.Assistant(get(message, "content", nothing), calls, result.finish, getfield(result, :status); metadata=message))
conversation_reply(message, calls, result) = Conversation.ModelReply(Conversation.Assistant(get(message, "content", nothing), calls, result.finish, result.done; metadata=message))

finish(message, result) = message["content"]
finish(message, result::Completion) = result.finish == "length" ? Truncated(result) : message["content"]

function modelresponse(agent, effect, parameters, on_event, on_agent_event)
    returned = false
    try
        messages = [convert(Dict{String, Any}, message) for message in effect.effect.messages]
        answer = response(agent, messages, parameters, on_event, on_agent_event)
        returned = true
        answer
    finally
        if !returned
            transition!(revision -> Kernel.Observe(revision, effect.id, Conversation.ModelFailure("provider did not return")), agent)
        end
    end
end

interrupt!(agent::Agent, ::Conversation.Phase) = nothing
interrupt!(agent::Agent, ::Union{Conversation.ReadyModelPhase, Conversation.ReadyDecisionPhase, Conversation.WaitingModelPhase, Conversation.WaitingToolsPhase}) = transition!(revision -> Conversation.Interrupt(revision, "turn interrupted"), agent)

"""
    respond!(agent, prompt; on_event=nothing, on_agent_event=nothing, parameters=Dict(), tool_execution=:sequential, executor=nothing, context=nothing)

Run a turn and queued messages. `on_event` receives provider stream events; `on_agent_event` receives lifecycle events. Tool calls run sequentially unless `tool_execution=:parallel`; recorded agents currently support sequential execution only. Returns `:busy` for an overlapping run and `:cancelled` for cooperative cancellation. Providers returning a `Completion` retain finish metadata; a custom provider returning only a message cannot report truncation.

Supplying `executor` and `context` selects the executor-backed path, including for a recorded agent. It returns an `Execution.Turn` with the outcome and per-model usage and error metadata; unsupported combinations return `Execution.Rejected` before starting. See `docs/execution.md` for its limitations.
"""
function respond!(agent::Agent, prompt; on_event=nothing, on_agent_event=nothing, parameters=Dict(), tool_execution=:sequential, executor=nothing, context=nothing)
    respond!(agent, prompt, executor, context; on_event, on_agent_event, parameters, tool_execution)
end

respond!(agent::Agent, prompt, executor, context; kwargs...) = respond_execution!(agent, prompt, executor, context; kwargs...)
respond!(agent::Agent, prompt, ::Nothing, ::Nothing; kwargs...) = respond!(agent, prompt, agent.history; kwargs...)
respond!(agent::Agent, prompt, ::History.Store; kwargs...) = respond_recorded!(agent, prompt; kwargs...)

function respond!(agent::Agent, prompt, ::Nothing; on_event, on_agent_event, parameters, tool_execution)
    begin!(agent) || return :busy
    messages = Dict{String, Any}[]
    event_lock = ReentrantLock()
    callback = on_agent_event
    on_agent_event = event -> lock(() -> emit(callback, event), event_lock)
    run = (; agent, on_event, callback=on_agent_event, parameters, tool_execution, messages)
    try
        emit(on_agent_event, (; type=:agent_start))
        emit(on_agent_event, (; type=:turn_start))
        direct_begin!(run, prompt)
    finally
        try
            interrupt!(agent, agent.state.phase)
            sync!(agent)
            emit(on_agent_event, (; type=:agent_end, messages=deepcopy(messages)))
        finally
            finish!(agent)
        end
    end
end

function direct_begin!(run, prompt)
    agent = run.agent
    sync!(agent)
    _, added = transition!(revision -> Conversation.Input(revision, prompt), agent)
    present!(agent, added, run.messages, run.callback)
    direct_cancel!(run, turnstate(agent))
    sync!(agent)
    next, added = transition!(revision -> Conversation.Advance(revision), agent)
    present!(agent, added, run.messages, run.callback)
    direct_ready!(run, next, turnstate(agent))
end

cancel_transition!(agent, ::Union{Idle, Running}) = nothing
cancel_transition!(agent, ::Cancelled) = cancel_transition!(agent, getfield(agent.state, :cancellation))
cancel_transition!(agent, ::Conversation.Requested) = nothing
function cancel_transition!(agent, ::Conversation.Active)
    result, _ = transition!(revision -> Conversation.Cancel(revision), agent)
    result
end

direct_cancel!(run, turn) = (cancel_transition!(run.agent, turn); nothing)

function direct_ready!(run, next, ::Cancelled)
    emit(run.callback, (; type=:turn_end, message=nothing, tool_results=Dict{String, Any}[]))
    :cancelled
end
direct_ready!(run, next, ::Union{Idle, Running}) = direct_loop!(run, only(next.effects))

function direct_loop!(run, effect)
    pending = Kernel.Pending[effect]
    result = Ref{Any}()
    while !isempty(pending)
        next = direct_step!(run, pop!(pending), turnstate(run.agent))
        schedule_pending!(pending, result, next)
    end
    result[]
end

function direct_step!(run, effect, ::Cancelled)
    transition!(revision -> Kernel.Observe(revision, effect.id, Conversation.ModelFailure("cancelled before dispatch")), run.agent)
    emit(run.callback, (; type=:turn_end, message=nothing, tool_results=Dict{String, Any}[]))
    :cancelled
end

function direct_step!(run, effect, ::Union{Idle, Running})
    answer = modelresponse(run.agent, effect, run.parameters, run.on_event, run.callback)
    outcome = conversation_reply(answer)
    result, added = transition!(revision -> Kernel.Observe(revision, effect.id, outcome), run.agent)
    direct_result!(run, answer, result, added, answer.result)
end

direct_result!(run, answer, transition, added, ::Nothing) = direct_complete!(run, answer, transition, added)
direct_result!(run, answer, transition, added, result::Completion) = direct_result!(run, answer, transition, added, result, getfield(result, :status))
direct_result!(run, answer, transition, added, result) = direct_result!(run, answer, transition, added, result, completionstatus(result.done))
direct_result!(run, answer, transition, added, result, ::Finished) = direct_complete!(run, answer, transition, added)
direct_result!(run, answer, transition, added, result, ::Unfinished) = direct_partial!(run, answer, result)

function direct_partial!(run, answer, result)
    message_start!(run.callback, answer.message, answer.started)
    emit(run.callback, (; type=:message_end, message=deepcopy(answer.message)))
    emit(run.callback, (; type=:turn_end, message=deepcopy(answer.message), tool_results=Dict{String, Any}[]))
    direct_partial!(result, turnstate(run.agent))
end
direct_partial!(result, ::Cancelled) = :cancelled
direct_partial!(result, ::Union{Idle, Running}) = result

function direct_complete!(run, answer, transition, added)
    agent = run.agent
    message = answer.message
    present!(agent, added, run.messages, run.callback; started=answer.started)
    results = runtools!(agent, transition.effects, run.messages, run.callback; tool_execution=run.tool_execution)
    emit(run.callback, (; type=:turn_end, message=deepcopy(message), tool_results=deepcopy(results)))
    sync!(agent)
    next, added = transition!(revision -> Conversation.Advance(revision), agent)
    direct_next!(run, message, answer.result, next, added, turnstate(agent))
end

direct_next!(run, message, completion, next, added, ::Cancelled) = :cancelled
function direct_next!(run, message, completion, next, added, ::Union{Idle, Running})
    isempty(next.effects) && return finish(message, completion)
    emit(run.callback, (; type=:turn_start))
    present!(run.agent, added, run.messages, run.callback)
    only(next.effects)
end
