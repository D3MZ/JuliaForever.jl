struct OpenAIResponses
    base::String
    model::String
    key::String
end

Base.show(io::IO, provider::OpenAIResponses) = print(io, "OpenAIResponses(", repr(provider.base), ", ", repr(provider.model), ", [redacted])")

headers(provider::OpenAIResponses) = ["Authorization" => "Bearer $(provider.key)", "Content-Type" => "application/json"]
endpoint(provider::OpenAIResponses) = "$(rstrip(provider.base, '/'))/responses"

const inputtypes = Dict("tool" => Conversation.ToolMessage, "assistant" => Conversation.Assistant)

function input(messages)
    items = Any[]
    foreach(message -> input!(items, get(inputtypes, message["role"], nothing), message), messages)
    items
end

input!(items, ::Nothing, message) = inputcontent!(items, message["role"], get(message, "content", nothing))
input!(items, ::Type{Conversation.ToolMessage}, message) = push!(items, Dict("type" => "function_call_output", "call_id" => message["tool_call_id"], "output" => message["content"]))

function input!(items, ::Type{Conversation.Assistant}, message)
    haskey(message, "response_output") && return append!(items, message["response_output"])
    inputcontent!(items, "assistant", get(message, "content", nothing))
    for call in get(message, "tool_calls", [])
        fn = call["function"]
        push!(items, Dict("type" => "function_call", "call_id" => call["id"], "name" => fn["name"], "arguments" => fn["arguments"]))
    end
    items
end

inputcontent!(items, role, ::Nothing) = nothing
inputcontent!(items, role, content) = push!(items, Dict("role" => role, "content" => content))

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

usage(::OpenAIResponses, ::Nothing) = nothing

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

const outputtypes = Dict("message" => Conversation.Assistant, "function_call" => Conversation.ToolCall)
const partfields = Dict("output_text" => "text", "refusal" => "refusal")

function message(output)
    result = Dict{String, Any}("role" => "assistant", "content" => nothing, "response_output" => output)
    calls = Any[]
    for item in output
        output!(result, calls, get(outputtypes, get(item, "type", nothing), nothing), item)
    end
    isempty(calls) || (result["tool_calls"] = calls)
    result
end

output!(result, calls, ::Nothing, item) = nothing

function output!(result, calls, ::Type{Conversation.Assistant}, item)
    for part in get(item, "content", [])
        field = get(partfields, get(part, "type", nothing), nothing)
        outputtext!(result, part, field)
    end
    nothing
end

function output!(result, calls, ::Type{Conversation.ToolCall}, item)
    push!(calls, Dict("id" => get(item, "call_id", ""), "type" => "function", "function" => Dict("name" => get(item, "name", ""), "arguments" => get(item, "arguments", ""))))
    nothing
end

outputtext!(result, part, ::Nothing) = nothing
outputtext!(result, part, field::String) = outputtext!(result, get(part, field, nothing))
outputtext!(result, text) = nothing

function outputtext!(result, text::AbstractString)
    result["content"] = jointext(result["content"], text)
    nothing
end

jointext(::Nothing, text) = text
jointext(current, text) = current * text

function valid(call)
    all(key -> get(call, key, nothing) isa AbstractString && !isempty(call[key]), ("id", "call_id", "name", "arguments")) && get(call, "status", "completed") == "completed"
end

completion(provider::OpenAIResponses, data::InvalidResponse; failure=nothing) = incomplete(data)
detail(value::AbstractString) = value
detail(value) = JSON3.write(value)

function completion(provider::OpenAIResponses, data; failure=nothing)
    output = get(data, "output", [])
    msg = message(output)
    status = get(data, "status", nothing)
    if isnothing(failure) && status != "completed"
        reason = something(get(data, "error", nothing), get(data, "incomplete_details", nothing), status, "missing status")
        failure = "Responses $(status): $(detail(reason))"
    end
    calls = [item for item in output if get(item, "type", nothing) == "function_call"]
    if isnothing(failure) && any(call -> !valid(call), calls)
        failure = "Responses contained an unfinished function call"
    elseif isnothing(failure) && (length(unique(call["id"] for call in calls)) != length(calls) || length(unique(call["call_id"] for call in calls)) != length(calls))
        failure = "Responses contained duplicate function call identifiers"
    end
    raw_usage = get(data, "usage", nothing)
    used = usage(provider, raw_usage)
    finish = status == "completed" ? (haskey(msg, "tool_calls") ? "tool_calls" : "stop") : status
    Completion(msg, used, finish, status == "completed" && isnothing(failure), failure)
end

function complete(provider::OpenAIResponses, messages, tools; parameters=Dict())
    response = HTTP.post(endpoint(provider), headers(provider), payload(provider, messages, tools, parameters); redirect=false, retry=false, cookies=false)
    completion(provider, decode(String(response.body)))
end

abstract type ResponseEvent end
struct TextDelta <: ResponseEvent
    text::Any
end
struct ThinkingDelta <: ResponseEvent
    field::String
    text::Any
end
struct OutputAdded <: ResponseEvent
    index::Any
    item::Any
end
struct ArgumentDelta <: ResponseEvent
    index::Any
    itemid::Any
    data::AbstractDict
end
struct OutputDone <: ResponseEvent
    index::Any
    item::Any
end
struct ResponseEnded <: ResponseEvent
    response::Any
end
struct ResponseError <: ResponseEvent
    message::String
end

const responseevents = Dict(
    "response.output_text.delta" => TextDelta, "response.refusal.delta" => TextDelta,
    "response.reasoning_summary_text.delta" => ThinkingDelta, "response.reasoning_text.delta" => ThinkingDelta,
    "response.output_item.added" => OutputAdded, "response.function_call_arguments.delta" => ArgumentDelta,
    "response.output_item.done" => OutputDone, "response.completed" => ResponseEnded,
    "response.incomplete" => ResponseEnded, "response.failed" => ResponseEnded, "error" => ResponseError,
)

responseevent(data::AbstractDict) = responseevent(get(responseevents, get(data, "type", nothing), nothing), data)
responseevent(::Nothing, data) = nothing
responseevent(::Type{TextDelta}, data) = TextDelta(data["delta"])
responseevent(::Type{ThinkingDelta}, data) = ThinkingDelta(data["type"], data["delta"])
responseevent(::Type{OutputAdded}, data) = OutputAdded(get(data, "output_index", nothing), data["item"])
responseevent(::Type{ArgumentDelta}, data) = ArgumentDelta(get(data, "output_index", nothing), get(data, "item_id", nothing), data)
responseevent(::Type{OutputDone}, data) = OutputDone(get(data, "output_index", nothing), data["item"])
responseevent(::Type{ResponseEnded}, data) = ResponseEnded(data["response"])
responseevent(::Type{ResponseError}, data) = ResponseError(JSON3.write(data))

mutable struct ResponseStream{F}
    partial::Dict{String, Any}
    active::Dict{Any, Any}
    finished::Dict{Any, Any}
    terminal::Any
    failure::Union{Nothing, String, InvalidResponse}
    callback::F
end

ResponseStream(callback) = ResponseStream(Dict{String, Any}("role" => "assistant", "content" => nothing), Dict{Any, Any}(), Dict{Any, Any}(), nothing, nothing, callback)
receive!(stream::ResponseStream, text::AbstractString) = receive!(stream, text, stream.failure)
receive!(stream::ResponseStream, text::AbstractString, ::InvalidResponse) = nothing

function receive!(stream::ResponseStream, text::AbstractString, failure)
    text == "[DONE]" && return nothing
    receive!(stream, decode(text))
end

receive!(stream::ResponseStream, failure::InvalidResponse) = (stream.failure = failure; nothing)

function receive!(stream::ResponseStream, data::AbstractDict)
    stream.callback((; type=:provider, data))
    handle!(stream, responseevent(data))
end

handle!(stream::ResponseStream, ::Nothing) = nothing

function handle!(stream::ResponseStream, event::TextDelta)
    stream.partial["content"] = jointext(stream.partial["content"], event.text)
    stream.callback((; type=:text, text=event.text))
    nothing
end

function handle!(stream::ResponseStream, event::ThinkingDelta)
    stream.callback((; type=:thinking, text=event.text, field=event.field))
    nothing
end

function handle!(stream::ResponseStream, event::OutputAdded)
    type = get(outputtypes, get(event.item, "type", nothing), nothing)
    start!(stream, event.index, event.item, type)
end

start!(stream::ResponseStream, index, item, type) = nothing
start!(stream::ResponseStream, index, item, ::Type{Conversation.ToolCall}) = start!(stream, index, item)
start!(stream::ResponseStream, ::Nothing, item) = (stream.failure = "Responses stream contained an ambiguous function call"; nothing)

function start!(stream::ResponseStream, index, item)
    if haskey(stream.active, index) || haskey(stream.finished, index)
        stream.failure = "Responses stream contained an ambiguous function call"
    else
        stream.active[index] = item
    end
    nothing
end

handle!(stream::ResponseStream, event::ArgumentDelta) = delta!(stream, event, get(stream.active, event.index, nothing))
delta!(stream::ResponseStream, event::ArgumentDelta, ::Nothing) = (stream.failure = "Responses stream contained an ambiguous function call delta"; nothing)

function delta!(stream::ResponseStream, event::ArgumentDelta, item)
    if get(item, "id", nothing) != event.itemid
        stream.failure = "Responses stream contained an ambiguous function call delta"
    else
        id = get(item, "call_id", nothing)
        name = get(item, "name", nothing)
        arguments = event.data["delta"]
        stream.callback((; type=:tool_call, index=event.index, id, name, arguments))
    end
    nothing
end

handle!(stream::ResponseStream, event::OutputDone) = done!(stream, event.index, event.item)
done!(stream::ResponseStream, ::Nothing, item) = (stream.failure = "Responses stream omitted an output index"; nothing)
done!(stream::ResponseStream, index, item) = done!(stream, index, item, get(outputtypes, get(item, "type", nothing), nothing))
done!(stream::ResponseStream, index, item, type) = (stream.finished[index] = item; nothing)
done!(stream::ResponseStream, index, item, ::Type{Conversation.ToolCall}) = finish!(stream, index, item, get(stream.active, index, nothing))
finish!(stream::ResponseStream, index, item, ::Nothing) = record!(stream, index, item)

function finish!(stream::ResponseStream, index, item, started)
    if get(started, "id", nothing) != get(item, "id", nothing) || get(started, "call_id", nothing) != get(item, "call_id", nothing)
        stream.failure = "Responses stream contained a mismatched function call"
    end
    record!(stream, index, item)
end

function record!(stream::ResponseStream, index, item)
    delete!(stream.active, index)
    stream.finished[index] = item
    nothing
end

handle!(stream::ResponseStream, event::ResponseEnded) = (stream.terminal = event.response; nothing)
handle!(stream::ResponseStream, event::ResponseError) = (stream.failure = event.message; nothing)

function stream(provider::OpenAIResponses, messages, tools; parameters=Dict(), on_event=identity)
    state = ResponseStream(on_event)
    HTTP.post(endpoint(provider), headers(provider), payload(provider, messages, tools, parameters; streaming=true); redirect=false, retry=false, cookies=false, sse_callback=event -> receive!(state, event.data))
    result = finish(provider, state, state.terminal)
    on_event((; type=completionevent(result), result))
    result
end

finish(provider::OpenAIResponses, state::ResponseStream, ::Nothing) = Completion(state.partial, nothing, nothing, false, something(state.failure, "Responses stream ended before a terminal event"))

function finish(provider::OpenAIResponses, state::ResponseStream, data)
    finished = state.finished
    if !haskey(data, "output")
        data["output"] = [finished[index] for index in sort!(collect(keys(finished)))]
    end
    for (index, item) in enumerate(data["output"])
        done = get(finished, index - 1, nothing)
        if get(item, "type", nothing) == "reasoning" && !isnothing(done) && get(done, "type", nothing) == "reasoning" && get(item, "id", nothing) == get(done, "id", nothing) && isnothing(get(item, "encrypted_content", nothing)) && !isnothing(get(done, "encrypted_content", nothing))
            item["encrypted_content"] = done["encrypted_content"]
        end
    end
    failure = reconcile!(state, data, state.failure)
    result = completion(provider, data; failure)
    isnothing(result.usage) || state.callback((; type=:usage, usage=result.usage))
    isnothing(result.finish) || state.callback((; type=:finish, reason=result.finish))
    result
end

reconcile!(state::ResponseStream, data, failure::InvalidResponse) = failure

function reconcile!(state::ResponseStream, data, failure)
    get(data, "status", nothing) == "completed" || return failure
    !isempty(state.active) && (failure = "Responses stream contained an unfinished function call")
    for (index, item) in enumerate(data["output"])
        if get(item, "type", nothing) == "function_call"
            done = get(state.finished, index - 1, nothing)
            if isnothing(done) || any(key -> get(item, key, nothing) != get(done, key, nothing), ("id", "call_id", "name", "arguments"))
                failure = "Responses stream contained an unfinished or mismatched function call"
            end
        end
    end
    for (index, item) in state.finished
        if get(item, "type", nothing) == "function_call" && (index >= length(data["output"]) || get(data["output"][index + 1], "type", nothing) != "function_call")
            failure = "Responses stream omitted a completed function call"
        end
    end
    failure
end
