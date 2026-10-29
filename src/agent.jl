export steer!, followup!, cancel!, abandon!

mutable struct Agent{P}
    provider::P
    tools::Dict{String, Tool}
    messages::Vector{Dict{String, Any}}
    initial::Conversation.State
    state::Conversation.State
    events::Vector{Kernel.Event}
    lock::ReentrantLock
    running::Bool
    cancelled::Bool
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
    value = getfield(agent, name)
    name === :events ? deepcopy(value) : value
end

function transition!(f, agent::Agent)
    lock(agent.lock) do
        !isnothing(agent.fault) && return agent.fault, Conversation.Message[]
        event = f(agent.state.revision)
        before = length(agent.state.messages)
        result = Kernel.step(agent.state, event)
        added = Conversation.Message[]
        if result isa Kernel.Applied
            saved = deepcopy(event)
            committed = persist!(agent, saved)
            committed isa History.Rejected && return committed, added
            agent.state = result.state
            push!(getfield(agent, :events), saved)
            added = result.state.messages[before+1:end]
        end
        result, added
    end
end

"Queue a user message for the next turn; steering is consumed one message at a time."
function steer!(agent::Agent, prompt)
    result, _ = transition!(revision -> Conversation.Steer(revision, prompt), agent)
    result isa History.Rejected ? result : nothing
end

"Queue a user message for when the agent would otherwise stop."
function followup!(agent::Agent, prompt)
    result, _ = transition!(revision -> Conversation.Followup(revision, prompt), agent)
    result isa History.Rejected ? result : nothing
end

"Request cancellation at the next boundary; in-flight provider and tool calls are not interrupted."
function cancel!(agent::Agent)
    lock(agent.lock) do
        agent.running || return false
        result, _ = transition!(revision -> Conversation.Cancel(revision), agent)
        result isa History.Rejected && return result
        agent.cancelled = true
        true
    end
end

cancelled(agent::Agent) = lock(() -> agent.cancelled, agent.lock)

function begin!(agent::Agent)
    lock(agent.lock) do
        agent.running && return false
        agent.running = true
        agent.cancelled = false
        true
    end
end

function Base.convert(::Type{Conversation.ToolCall}, call::AbstractDict)
    info = callinfo(call)
    name = info.name isa AbstractString ? String(info.name) : nothing
    args = info.args isa AbstractString ? String(info.args) : nothing
    Conversation.ToolCall(String(call["id"]), name, args; metadata=call)
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
    Dict{String, Any}("role" => "tool", "tool_call_id" => message.id, "content" => message.content)
end

Base.convert(::Type{Dict{String, Any}}, message::Conversation.RawMessage) = deepcopy(message.value)

function sync!(agent::Agent)
    result = lock(agent.lock) do
        recorded = [convert(Dict{String, Any}, message) for message in agent.state.messages]
        if !Kernel.same(recorded, agent.messages)
            history = Conversation.Message[Conversation.RawMessage(deepcopy(message)) for message in agent.messages]
            result, _ = transition!(revision -> Conversation.History(revision, history), agent)
            result isa History.Rejected && return result
        end
        nothing
    end
    result
end

function finish!(agent::Agent)
    lock(agent.lock) do
        agent.running = false
        agent.cancelled = false
    end
end

name(::Read) = "read"
name(::Write) = "write"
name(::Edit) = "edit"

schema(::Read) = Dict("type" => "object", "properties" => Dict("path" => Dict("type" => "string"), "offset" => Dict("type" => "integer"), "limit" => Dict("type" => "integer")), "required" => ["path"])
schema(::Write) = Dict("type" => "object", "properties" => Dict("path" => Dict("type" => "string"), "content" => Dict("type" => "string")), "required" => ["path", "content"])
schema(::Edit) = Dict("type" => "object", "properties" => Dict("path" => Dict("type" => "string"), "edits" => Dict("type" => "array", "items" => Dict("type" => "object", "properties" => Dict("oldText" => Dict("type" => "string"), "newText" => Dict("type" => "string")), "required" => ["oldText", "newText"]))), "required" => ["path", "edits"])

description(::Read) = "Read a text file. Offset and limit are line based."
description(::Write) = "Create or overwrite a text file."
description(::Edit) = "Replace unique, non-overlapping text in a file."

definition(tool) = Dict("type" => "function", "function" => Dict("name" => name(tool), "description" => description(tool), "parameters" => schema(tool)))

function invoke(agent, call)
    try
        tool = call["function"]
        execute(agent.tools[tool["name"]], JSON3.read(tool["arguments"]))
    catch exception
        ToolResult(sprint(showerror, exception), true)
    end
end

emit(callback, event) = isnothing(callback) ? nothing : callback(event)

function record!(agent, message, messages, on_agent_event; started=false)
    started || emit(on_agent_event, (; type=:message_start, message=deepcopy(message)))
    push!(agent.messages, message)
    push!(messages, message)
    emit(on_agent_event, (; type=:message_end, message=deepcopy(message)))
end

function present!(agent, added, messages, on_agent_event; started=false)
    for (index, message) in enumerate(added)
        record!(agent, convert(Dict{String, Any}, message), messages, on_agent_event; started=started && index == 1)
    end
end

function update!(partial, calls, event)
    if event.type == :text
        content = partial["content"]
        partial["content"] = isnothing(content) ? event.text : content * event.text
    elseif event.type == :thinking
        partial["reasoning_content"] = get(partial, "reasoning_content", "") * event.text
    elseif event.type == :tool_call
        if !haskey(calls, event.index)
            calls[event.index] = Dict("id" => "", "type" => "function", "function" => Dict("name" => "", "arguments" => ""))
            push!(get!(partial, "tool_calls", []), calls[event.index])
        end
        call = calls[event.index]
        !isnothing(event.id) && isempty(call["id"]) && (call["id"] = event.id)
        !isnothing(event.name) && isempty(call["function"]["name"]) && (call["function"]["name"] = event.name)
        call["function"]["arguments"] *= event.arguments
    end
end

function response(agent, messages, parameters, on_event, on_agent_event)
    if isnothing(on_event)
        message = isempty(parameters) ? complete(agent.provider, messages, agent.tools) : complete(agent.provider, messages, agent.tools; parameters)
        message isa Completion && return (; message=message.message, result=message, started=false)
        return (; message, result=nothing, started=false)
    end
    partial = Dict{String, Any}("role" => "assistant", "content" => nothing)
    calls = Dict{Any, Any}()
    started = Ref(false)
    result = stream(agent.provider, messages, agent.tools; parameters, on_event=event -> begin
        on_event(event)
        if event.type in (:text, :thinking, :tool_call)
            if !started[]
                emit(on_agent_event, (; type=:message_start, message=deepcopy(partial)))
                started[] = true
            end
            update!(partial, calls, event)
            emit(on_agent_event, (; type=:message_update, assistant_event=event, message=deepcopy(partial)))
        end
    end)
    (; message=result.message, result, started=started[])
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

function toolresult(agent, call, on_agent_event; truncated=false)
    info = callinfo(call)
    id = call["id"]
    result = if cancelled(agent)
        ToolResult("Operation cancelled", true)
    elseif truncated
        ToolResult("Tool call \"$(info.name)\" was not executed: the response hit the output token limit, so its arguments may be truncated. Re-issue the tool call with complete arguments.", true)
    else
        invoke(agent, call)
    end
    emit(on_agent_event, (; type=:tool_execution_end, tool_call_id=id, tool_name=info.name, result, iserror=result.iserror))
    result
end

function toolmessage(call, result)
    content = result.iserror ? "Error: $(result.text)" : result.text
    Dict{String, Any}("role" => "tool", "tool_call_id" => call["id"], "content" => content)
end

function toolobserve!(agent, effect, result, messages, on_agent_event)
    transition, added = transition!(revision -> Kernel.Observe(revision, effect.id, Conversation.ToolReply(result.text, result.iserror)), agent)
    present!(agent, added, messages, on_agent_event)
    transition
end

function runtools!(agent, effects, messages, on_agent_event; tool_execution=:sequential)
    results = Dict{String, Any}[]
    calls = [convert(Dict{String, Any}, effect.effect.call) for effect in effects]
    if tool_execution == :parallel && all(effect -> effect.effect isa Conversation.ToolRequest, effects)
        foreach(call -> toolstart(call, on_agent_event), calls)
        completed = Vector{ToolResult}(undef, length(calls))
        @sync for i in eachindex(calls)
            Threads.@spawn completed[i] = toolresult(agent, calls[i], on_agent_event)
        end
        for i in eachindex(calls)
            toolobserve!(agent, effects[i], completed[i], messages, on_agent_event)
            push!(results, toolmessage(calls[i], completed[i]))
        end
    else
        for (effect, call) in zip(effects, calls)
            toolstart(call, on_agent_event)
            result = toolresult(agent, call, on_agent_event; truncated=effect.effect isa Conversation.SkipRequest)
            toolobserve!(agent, effect, result, messages, on_agent_event)
            push!(results, toolmessage(call, result))
        end
    end
    results
end

function conversation_reply(answer)
    message = answer.message
    calls = Conversation.ToolCall[convert(Conversation.ToolCall, call) for call in get(message, "tool_calls", [])]
    result = answer.result
    finish = isnothing(result) ? nothing : result.finish
    done = isnothing(result) || result.done
    Conversation.ModelReply(Conversation.Assistant(get(message, "content", nothing), calls, finish, done; metadata=message))
end

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

"""
    respond!(agent, prompt; on_event=nothing, on_agent_event=nothing, parameters=Dict(), tool_execution=:sequential)

Run a turn and queued messages. `on_event` receives provider stream events; `on_agent_event` receives lifecycle events. Tool calls run sequentially unless `tool_execution=:parallel`; recorded agents currently support sequential execution only. Returns `:busy` for an overlapping run and `:cancelled` for cooperative cancellation. Providers returning a `Completion` retain finish metadata; a custom provider returning only a message cannot report truncation.
"""
function respond!(agent::Agent, prompt; on_event=nothing, on_agent_event=nothing, parameters=Dict(), tool_execution=:sequential)
    !isnothing(agent.history) && return respond_recorded!(agent, prompt; on_event, on_agent_event, parameters, tool_execution)
    begin!(agent) || return :busy
    messages = Dict{String, Any}[]
    event_lock = ReentrantLock()
    callback = on_agent_event
    on_agent_event = event -> lock(() -> emit(callback, event), event_lock)
    try
        emit(on_agent_event, (; type=:agent_start))
        emit(on_agent_event, (; type=:turn_start))
        sync!(agent)
        _, added = transition!(revision -> Conversation.Input(revision, prompt), agent)
        present!(agent, added, messages, on_agent_event)
        if cancelled(agent) && !agent.state.cancelled
            transition!(revision -> Conversation.Cancel(revision), agent)
        end
        sync!(agent)
        next, added = transition!(revision -> Conversation.Advance(revision), agent)
        present!(agent, added, messages, on_agent_event)
        if cancelled(agent)
            emit(on_agent_event, (; type=:turn_end, message=nothing, tool_results=Dict{String, Any}[]))
            return :cancelled
        end
        effect = only(next.effects)
        while true
            if cancelled(agent)
                transition!(revision -> Kernel.Observe(revision, effect.id, Conversation.ModelFailure("cancelled before dispatch")), agent)
                emit(on_agent_event, (; type=:turn_end, message=nothing, tool_results=Dict{String, Any}[]))
                return :cancelled
            end
            answer = modelresponse(agent, effect, parameters, on_event, on_agent_event)
            result = answer.result
            outcome = conversation_reply(answer)
            transition, added = transition!(revision -> Kernel.Observe(revision, effect.id, outcome), agent)
            if !isnothing(result) && !result.done
                answer.started || emit(on_agent_event, (; type=:message_start, message=deepcopy(answer.message)))
                emit(on_agent_event, (; type=:message_end, message=deepcopy(answer.message)))
                emit(on_agent_event, (; type=:turn_end, message=deepcopy(answer.message), tool_results=Dict{String, Any}[]))
                return cancelled(agent) ? :cancelled : result
            end
            message = answer.message
            present!(agent, added, messages, on_agent_event; started=answer.started)
            results = runtools!(agent, transition.effects, messages, on_agent_event; tool_execution)
            emit(on_agent_event, (; type=:turn_end, message=deepcopy(message), tool_results=deepcopy(results)))
            sync!(agent)
            next, added = transition!(revision -> Conversation.Advance(revision), agent)
            cancelled(agent) && return :cancelled
            isempty(next.effects) && return message["content"]
            emit(on_agent_event, (; type=:turn_start))
            present!(agent, added, messages, on_agent_event)
            effect = only(next.effects)
        end
    finally
        try
            if agent.state.phase in (Conversation.ReadyModel, Conversation.ReadyDecision, Conversation.WaitingModel, Conversation.WaitingTools)
                transition!(revision -> Conversation.Interrupt(revision, "turn interrupted"), agent)
            end
            sync!(agent)
            emit(on_agent_event, (; type=:agent_end, messages=deepcopy(messages)))
        finally
            finish!(agent)
        end
    end
end
