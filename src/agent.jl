export steer!, followup!, cancel!

mutable struct Agent{P}
    provider::P
    tools::Dict{String, Tool}
    messages::Vector{Dict{String, Any}}
    steering::Vector{Dict{String, Any}}
    followups::Vector{Dict{String, Any}}
    lock::ReentrantLock
    running::Bool
    cancelled::Bool
end

Agent(provider, tools, messages) = Agent(provider, tools, messages, Dict{String, Any}[], Dict{String, Any}[], ReentrantLock(), false, false)
Agent(provider, tools) = Agent(provider, Dict{String, Tool}(name(tool) => tool for tool in tools), Dict{String, Any}[])

function enqueue!(agent::Agent, queue, prompt)
    lock(agent.lock) do
        push!(queue, Dict("role" => "user", "content" => prompt))
    end
    nothing
end

"Queue a user message for the next turn; steering is consumed one message at a time."
steer!(agent::Agent, prompt) = enqueue!(agent, agent.steering, prompt)
"Queue a user message for when the agent would otherwise stop."
followup!(agent::Agent, prompt) = enqueue!(agent, agent.followups, prompt)

"Request cancellation at the next boundary; in-flight provider and tool calls are not interrupted."
function cancel!(agent::Agent)
    lock(agent.lock) do
        agent.running || return false
        agent.cancelled = true
        true
    end
end

cancelled(agent::Agent) = lock(() -> agent.cancelled, agent.lock)

function dequeue!(agent::Agent, queue)
    lock(agent.lock) do
        isempty(queue) ? nothing : popfirst!(queue)
    end
end

function begin!(agent::Agent)
    lock(agent.lock) do
        agent.running && return false
        agent.running = true
        agent.cancelled = false
        true
    end
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

function response(agent, parameters, on_event, on_agent_event)
    if isnothing(on_event)
        message = isempty(parameters) ? complete(agent.provider, agent.messages, agent.tools) : complete(agent.provider, agent.messages, agent.tools; parameters)
        return (; message, result=nothing, started=false)
    end
    partial = Dict{String, Any}("role" => "assistant", "content" => nothing)
    calls = Dict{Any, Any}()
    started = Ref(false)
    result = stream(agent.provider, agent.messages, agent.tools; parameters, on_event=event -> begin
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
    content = result.iserror ? "Error: $(result.text)" : result.text
    Dict{String, Any}("role" => "tool", "tool_call_id" => id, "content" => content)
end

function runtools!(agent, calls, messages, on_agent_event; truncated=false, tool_execution=:sequential)
    results = Dict{String, Any}[]
    if tool_execution == :parallel && !truncated
        foreach(call -> toolstart(call, on_agent_event), calls)
        completed = Vector{Dict{String, Any}}(undef, length(calls))
        @sync for i in eachindex(calls)
            Threads.@spawn completed[i] = toolresult(agent, calls[i], on_agent_event)
        end
        for result in completed
            record!(agent, result, messages, on_agent_event)
            push!(results, result)
        end
    else
        for call in calls
            toolstart(call, on_agent_event)
            result = toolresult(agent, call, on_agent_event; truncated)
            record!(agent, result, messages, on_agent_event)
            push!(results, result)
        end
    end
    results
end

"""
    respond!(agent, prompt; on_event=nothing, on_agent_event=nothing, parameters=Dict(), tool_execution=:sequential)

Run a turn and queued messages. `on_event` receives provider stream events; `on_agent_event` receives lifecycle events. Tool calls run sequentially unless `tool_execution=:parallel`. Returns `:busy` for an overlapping run and `:cancelled` for cooperative cancellation. Without `on_event`, the legacy completion API does not provide a finish reason, so truncation cannot be detected.
"""
function respond!(agent::Agent, prompt; on_event=nothing, on_agent_event=nothing, parameters=Dict(), tool_execution=:sequential)
    begin!(agent) || return :busy
    messages = Dict{String, Any}[]
    event_lock = ReentrantLock()
    callback = on_agent_event
    on_agent_event = event -> lock(() -> emit(callback, event), event_lock)
    try
        emit(on_agent_event, (; type=:agent_start))
        emit(on_agent_event, (; type=:turn_start))
        record!(agent, Dict{String, Any}("role" => "user", "content" => prompt), messages, on_agent_event)
        pending = dequeue!(agent, agent.steering)
        firstturn = true
        while true
            firstturn || emit(on_agent_event, (; type=:turn_start))
            firstturn = false
            isnothing(pending) || record!(agent, pending, messages, on_agent_event)
            if cancelled(agent)
                emit(on_agent_event, (; type=:turn_end, message=nothing, tool_results=Dict{String, Any}[]))
                return :cancelled
            end
            answer = response(agent, parameters, on_event, on_agent_event)
            result = answer.result
            if !isnothing(result) && !result.done
                answer.started || emit(on_agent_event, (; type=:message_start, message=deepcopy(answer.message)))
                emit(on_agent_event, (; type=:message_end, message=deepcopy(answer.message)))
                emit(on_agent_event, (; type=:turn_end, message=deepcopy(answer.message), tool_results=Dict{String, Any}[]))
                return cancelled(agent) ? :cancelled : result
            end
            message = answer.message
            record!(agent, message, messages, on_agent_event; started=answer.started)
            calls = get(message, "tool_calls", [])
            truncated = !isnothing(result) && result.finish == "length"
            results = runtools!(agent, calls, messages, on_agent_event; truncated, tool_execution)
            emit(on_agent_event, (; type=:turn_end, message=deepcopy(message), tool_results=deepcopy(results)))
            cancelled(agent) && return :cancelled
            pending = dequeue!(agent, agent.steering)
            if isempty(calls) && isnothing(pending)
                pending = dequeue!(agent, agent.followups)
                isnothing(pending) && return message["content"]
            end
        end
    finally
        try
            emit(on_agent_event, (; type=:agent_end, messages=deepcopy(messages)))
        finally
            finish!(agent)
        end
    end
end
