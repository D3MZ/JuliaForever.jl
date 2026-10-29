struct OpenAIResponses
    base::String
    model::String
    key::String
end

Base.show(io::IO, provider::OpenAIResponses) = print(io, "OpenAIResponses(", repr(provider.base), ", ", repr(provider.model), ", [redacted])")

headers(provider::OpenAIResponses) = ["Authorization" => "Bearer $(provider.key)", "Content-Type" => "application/json"]
endpoint(provider::OpenAIResponses) = "$(rstrip(provider.base, '/'))/responses"

function input(messages)
    items = Any[]
    for message in messages
        role = message["role"]
        if role == "tool"
            push!(items, Dict("type" => "function_call_output", "call_id" => message["tool_call_id"], "output" => message["content"]))
        elseif role == "assistant" && haskey(message, "response_output")
            append!(items, message["response_output"])
        else
            content = get(message, "content", nothing)
            isnothing(content) || push!(items, Dict("role" => role, "content" => content))
            if role == "assistant"
                for call in get(message, "tool_calls", [])
                    fn = call["function"]
                    push!(items, Dict("type" => "function_call", "call_id" => call["id"], "name" => fn["name"], "arguments" => fn["arguments"]))
                end
            end
        end
    end
    items
end

function payload(provider::OpenAIResponses, messages, tools, parameters; streaming=false)
    data = Dict{String, Any}(string(key) => value for (key, value) in pairs(parameters))
    data["model"] = provider.model
    data["input"] = input(messages)
    data["stream"] = streaming
    get!(data, "store", false)
    include = get(data, "include", [])
    data["include"] = "reasoning.encrypted_content" in include ? include : [include..., "reasoning.encrypted_content"]
    delete!(data, "messages")
    delete!(data, "tools")
    delete!(data, "stream_options")
    if !isempty(tools)
        data["tools"] = [merge(Dict("type" => "function", "strict" => false), definition(tool)["function"]) for tool in values(tools)]
    end
    JSON3.write(data)
end

function usage(::OpenAIResponses, data)
    raw_input = get(data, "input_tokens", 0)
    output = get(data, "output_tokens", 0)
    input_details = something(get(data, "input_tokens_details", nothing), Dict())
    output_details = something(get(data, "output_tokens_details", nothing), Dict())
    cache_read = get(input_details, "cached_tokens", 0)
    cache_write = get(input_details, "cache_write_tokens", 0)
    reasoning = get(output_details, "reasoning_tokens", 0)
    Usage(max(0, raw_input - cache_read - cache_write), output, cache_read, cache_write, reasoning, get(data, "total_tokens", raw_input + output), nothing)
end

function message(output)
    result = Dict{String, Any}("role" => "assistant", "content" => nothing, "response_output" => output)
    calls = Any[]
    for item in output
        if get(item, "type", nothing) == "message"
            for part in get(item, "content", [])
                text = get(part, "type", nothing) == "output_text" ? get(part, "text", nothing) : get(part, "type", nothing) == "refusal" ? get(part, "refusal", nothing) : nothing
                if text isa AbstractString
                    current = result["content"]
                    result["content"] = isnothing(current) ? text : current * text
                end
            end
        elseif get(item, "type", nothing) == "function_call"
            push!(calls, Dict("id" => get(item, "call_id", ""), "type" => "function", "function" => Dict("name" => get(item, "name", ""), "arguments" => get(item, "arguments", ""))))
        end
    end
    isempty(calls) || (result["tool_calls"] = calls)
    result
end

function valid(call)
    all(key -> get(call, key, nothing) isa AbstractString && !isempty(call[key]), ("id", "call_id", "name", "arguments")) && get(call, "status", "completed") == "completed"
end

function completion(provider::OpenAIResponses, data; failure=nothing)
    output = get(data, "output", [])
    msg = message(output)
    status = get(data, "status", nothing)
    if isnothing(failure) && status != "completed"
        detail = something(get(data, "error", nothing), get(data, "incomplete_details", nothing), status, "missing status")
        failure = "Responses $(status): $(detail isa AbstractString ? detail : JSON3.write(detail))"
    end
    calls = [item for item in output if get(item, "type", nothing) == "function_call"]
    if isnothing(failure) && any(call -> !valid(call), calls)
        failure = "Responses contained an unfinished function call"
    elseif isnothing(failure) && (length(unique(call["id"] for call in calls)) != length(calls) || length(unique(call["call_id"] for call in calls)) != length(calls))
        failure = "Responses contained duplicate function call identifiers"
    end
    raw_usage = get(data, "usage", nothing)
    used = isnothing(raw_usage) ? nothing : usage(provider, raw_usage)
    finish = status == "completed" ? (haskey(msg, "tool_calls") ? "tool_calls" : "stop") : status
    Completion(msg, used, finish, status == "completed" && isnothing(failure), failure)
end

function complete(provider::OpenAIResponses, messages, tools; parameters=Dict())
    response = HTTP.post(endpoint(provider), headers(provider), payload(provider, messages, tools, parameters); redirect=false, retry=false, cookies=false)
    completion(provider, JSON3.read(String(response.body), Dict{String, Any}))
end

function stream(provider::OpenAIResponses, messages, tools; parameters=Dict(), on_event=identity)
    partial = Dict{String, Any}("role" => "assistant", "content" => nothing)
    active = Dict{Any, Any}()
    finished = Dict{Any, Any}()
    terminal = Ref{Any}(nothing)
    failure = Ref{Union{Nothing, String}}(nothing)
    HTTP.post(endpoint(provider), headers(provider), payload(provider, messages, tools, parameters; streaming=true); redirect=false, retry=false, cookies=false, sse_callback=event -> begin
        event.data == "[DONE]" && return
        data = JSON3.read(event.data, Dict{String, Any})
        on_event((; type=:provider, data))
        kind = get(data, "type", nothing)
        if kind in ("response.output_text.delta", "response.refusal.delta")
            text = data["delta"]
            current = partial["content"]
            partial["content"] = isnothing(current) ? text : current * text
            on_event((; type=:text, text))
        elseif kind in ("response.reasoning_summary_text.delta", "response.reasoning_text.delta")
            text = data["delta"]
            field = kind
            on_event((; type=:thinking, text, field))
        elseif kind == "response.output_item.added" && get(data["item"], "type", nothing) == "function_call"
            index = get(data, "output_index", nothing)
            item = data["item"]
            if isnothing(index) || haskey(active, index) || haskey(finished, index)
                failure[] = "Responses stream contained an ambiguous function call"
            else
                active[index] = item
            end
        elseif kind == "response.function_call_arguments.delta"
            index = get(data, "output_index", nothing)
            item = get(active, index, nothing)
            if isnothing(item) || get(item, "id", nothing) != get(data, "item_id", nothing)
                failure[] = "Responses stream contained an ambiguous function call delta"
            else
                id = get(item, "call_id", nothing)
                name = get(item, "name", nothing)
                arguments = data["delta"]
                on_event((; type=:tool_call, index, id, name, arguments))
            end
        elseif kind == "response.output_item.done"
            index = get(data, "output_index", nothing)
            item = data["item"]
            if isnothing(index)
                failure[] = "Responses stream omitted an output index"
            elseif get(item, "type", nothing) == "function_call"
                started = get(active, index, nothing)
                if !isnothing(started) && (get(started, "id", nothing) != get(item, "id", nothing) || get(started, "call_id", nothing) != get(item, "call_id", nothing))
                    failure[] = "Responses stream contained a mismatched function call"
                end
                delete!(active, index)
                finished[index] = item
            else
                finished[index] = item
            end
        elseif kind in ("response.completed", "response.incomplete", "response.failed")
            terminal[] = data["response"]
        elseif kind == "error"
            failure[] = JSON3.write(data)
        end
    end)
    if isnothing(terminal[])
        result = Completion(partial, nothing, nothing, false, something(failure[], "Responses stream ended before a terminal event"))
    else
        data = terminal[]
        if !haskey(data, "output")
            data["output"] = [finished[index] for index in sort!(collect(keys(finished)))]
        end
        for (index, item) in enumerate(data["output"])
            done = get(finished, index - 1, nothing)
            if get(item, "type", nothing) == "reasoning" && !isnothing(done) && get(done, "type", nothing) == "reasoning" && get(item, "id", nothing) == get(done, "id", nothing) && isnothing(get(item, "encrypted_content", nothing)) && !isnothing(get(done, "encrypted_content", nothing))
                item["encrypted_content"] = done["encrypted_content"]
            end
        end
        if get(data, "status", nothing) == "completed"
            if !isempty(active)
                failure[] = "Responses stream contained an unfinished function call"
            end
            for (index, item) in enumerate(data["output"])
                if get(item, "type", nothing) == "function_call"
                    done = get(finished, index - 1, nothing)
                    if isnothing(done) || any(key -> get(item, key, nothing) != get(done, key, nothing), ("id", "call_id", "name", "arguments"))
                        failure[] = "Responses stream contained an unfinished or mismatched function call"
                    end
                end
            end
            for (index, item) in finished
                if get(item, "type", nothing) == "function_call" && (index >= length(data["output"]) || get(data["output"][index + 1], "type", nothing) != "function_call")
                    failure[] = "Responses stream omitted a completed function call"
                end
            end
        end
        result = completion(provider, data; failure=failure[])
        isnothing(result.usage) || on_event((; type=:usage, usage=result.usage))
        isnothing(result.finish) || on_event((; type=:finish, reason=result.finish))
    end
    on_event((; type=result.done ? :done : :incomplete, result))
    result
end
