struct OpenAIResponses
    base::String
    model::String
    key::String
end

Base.show(io::IO, provider::OpenAIResponses) = print(io, "OpenAIResponses(", repr(provider.model), ", [redacted])")
StructTypes.StructType(::Type{OpenAIResponses}) = StructTypes.CustomStruct()
StructTypes.lower(provider::OpenAIResponses) = (; model=provider.model, credentials="[redacted]")

headers(provider::OpenAIResponses) = ["Authorization" => "Bearer $(provider.key)", "Content-Type" => "application/json"]
endpoint(provider::OpenAIResponses) = "$(rstrip(provider.base, '/'))/responses"

const inputtypes = Dict("tool" => Conversation.ToolMessage, "assistant" => Conversation.Assistant, "user" => Conversation.User)
tooloutput(content, ::Nothing) = content
tooloutput(content, image) = [Dict("type" => "input_text", "text" => content), Dict("type" => "input_image", "detail" => "auto", "image_url" => "data:$(image["mime"]);base64,$(image["data"])")]

function input(messages)
    items = Any[]
    foreach(message -> input!(items, get(inputtypes, message["role"], nothing), message), messages)
    items
end

input!(items, ::Nothing, message) = inputcontent!(items, message["role"], get(message, "content", nothing))
input!(items, ::Type{Conversation.User}, message) = inputuser!(items, message, get(message, "images", nothing))
inputuser!(items, message, ::Nothing) = inputcontent!(items, "user", get(message, "content", nothing))
function inputuser!(items, message, attachments::AbstractVector)
    parts = [Dict("type" => "input_text", "text" => message["content"]), (Dict("type" => "input_image", "detail" => "auto", "image_url" => "data:$(image["mime"]);base64,$(image["data"])") for image in attachments)...]
    push!(items, Dict("role" => "user", "content" => parts))
end
input!(items, ::Type{Conversation.ToolMessage}, message) = push!(items, Dict("type" => "function_call_output", "call_id" => message["tool_call_id"], "output" => tooloutput(message["content"], get(message, "image", nothing))))

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

struct ReasoningOutput
    id
    encrypted
end

const outputtypes = Dict("message" => Conversation.Assistant, "function_call" => Conversation.ToolCall, "reasoning" => ReasoningOutput)
const partfields = Dict("output_text" => "text", "refusal" => "refusal")

reasoning(::Nothing) = nothing
reasoning(item) = reasoning(get(outputtypes, get(item, "type", nothing), nothing), item)
reasoning(type, item) = nothing
reasoning(::Type{ReasoningOutput}, item) = ReasoningOutput(get(item, "id", nothing), get(item, "encrypted_content", nothing))

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
output!(result, calls, ::Type{ReasoningOutput}, item) = nothing

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

const responsestatuses = Dict("completed" => Finished())
responsestatus(status) = get(responsestatuses, status, Unfinished())

const unfinishedcall = "Responses contained an unfinished function call"
checkcall(call) = checkcall(call, responsestatus(get(call, "status", "completed")))
checkcall(call, ::Unfinished) = unfinishedcall
checkcall(call, ::Finished) = foldl((failure, key) -> checkfield(failure, call, key), ("id", "call_id", "name", "arguments"); init=nothing)
checkfield(failure::String, call, key) = failure
checkfield(::Nothing, call, key) = checkfield(get(call, key, nothing))
checkfield(value) = unfinishedcall
checkfield(value::AbstractString) = isempty(value) ? unfinishedcall : nothing
callcheck(failure::String, call) = failure
callcheck(::Nothing, call) = checkcall(call)

function responsecalls(output)
    calls = Any[]
    for item in output
        responsecalls!(calls, item, get(outputtypes, get(item, "type", nothing), nothing))
    end
    calls
end
responsecalls!(calls, item, type) = nothing
responsecalls!(calls, item, ::Type{Conversation.ToolCall}) = push!(calls, item)

completion(provider::OpenAIResponses, data::InvalidResponse; failure=nothing) = incomplete(data)
const saferesponsestatuses = Dict(status => status for status in ("failed", "incomplete", "cancelled", "canceled", "queued", "in_progress"))
saferesponsestatus(status) = nothing
saferesponsestatus(status::AbstractString) = get(saferesponsestatuses, status, nothing)

responsefailure(data, raw, status, failure) = failure
function responsefailure(data, raw, ::Unfinished, ::Nothing)
    reason = something(get(data, "error", nothing), get(data, "incomplete_details", nothing), raw, "missing status")
    providererror(:openai_responses, reason)
end

callfailure(calls, failure) = failure
callfailure(calls, ::Nothing) = checkedcalls(calls, foldl(callcheck, calls; init=nothing))
checkedcalls(calls, failure::String) = failure
function checkedcalls(calls, ::Nothing)
    length(unique(call["id"] for call in calls)) == length(calls) && length(unique(call["call_id"] for call in calls)) == length(calls) || return "Responses contained duplicate function call identifiers"
    nothing
end

responsefinish(raw, ::Unfinished, calls) = saferesponsestatus(raw)
responsefinish(raw, ::Finished, ::Nothing) = "stop"
responsefinish(raw, ::Finished, calls) = "tool_calls"
responsecomplete(status, failure) = Unfinished()
responsecomplete(::Finished, ::Nothing) = Finished()

function completion(provider::OpenAIResponses, data; failure=nothing)
    output = get(data, "output", [])
    msg = message(output)
    raw = get(data, "status", nothing)
    status = responsestatus(raw)
    failure = responsefailure(data, raw, status, failure)
    failure = callfailure(responsecalls(output), failure)
    used = usage(provider, get(data, "usage", nothing))
    finish = responsefinish(raw, status, get(msg, "tool_calls", nothing))
    Completion(msg, used, finish, responsecomplete(status, failure), failure)
end

requestcontext(::OpenAIResponses) = HTTP.RequestContext()

function complete(provider::OpenAIResponses, messages, tools; parameters=Dict())
    response = HTTP.post(endpoint(provider), headers(provider), payload(provider, messages, tools, parameters); redirect=false, retry=false, cookies=false, status_exception=false, context=requestcontext())
    200 <= response.status < 300 || return incomplete(ProviderStatus(response.status))
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
    failure::ProviderError
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
responseevent(::Type{ResponseError}, data) = ResponseError(providererror(:openai_responses, data))

mutable struct ResponseStream{F}
    partial::Dict{String, Any}
    active::Dict{Any, Any}
    finished::Dict{Any, Any}
    terminal::Any
    failure::Union{Nothing, String, InvalidResponse, ProviderError}
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
handle!(stream::ResponseStream, event::ResponseError) = (stream.failure = event.failure; nothing)

function stream(provider::OpenAIResponses, messages, tools; parameters=Dict(), on_event=identity)
    state = ResponseStream(on_event)
    response = HTTP.post(endpoint(provider), headers(provider), payload(provider, messages, tools, parameters; streaming=true); redirect=false, retry=false, cookies=false, status_exception=false, context=requestcontext(), sse_callback=event -> receive!(state, event.data))
    result = 200 <= response.status < 300 ? finish(provider, state, state.terminal) : incomplete(ProviderStatus(response.status))
    on_event((; type=completionevent(result), result))
    result
end

finish(provider::OpenAIResponses, state::ResponseStream, ::Nothing) = Completion(state.partial, nothing, nothing, Unfinished(), something(state.failure, "Responses stream ended before a terminal event"))

function finish(provider::OpenAIResponses, state::ResponseStream, data)
    finished = state.finished
    if !haskey(data, "output")
        data["output"] = [finished[index] for index in sort!(collect(keys(finished)))]
    end
    for (index, item) in enumerate(data["output"])
        recover_reasoning!(item, get(finished, index - 1, nothing))
    end
    failure = reconcile!(state, data, state.failure)
    result = completion(provider, data; failure)
    emitusage(state.callback, result.usage)
    emitfinish(state.callback, result.finish)
    result
end

recover_reasoning!(item, done) = recover_reasoning!(item, done, get(outputtypes, get(item, "type", nothing), nothing))
recover_reasoning!(item, done, type) = nothing
recover_reasoning!(item, done, ::Type{ReasoningOutput}) = recover_reasoning!(item, reasoning(done))
recover_reasoning!(item, ::Nothing) = nothing
function recover_reasoning!(item, source::ReasoningOutput)
    get(item, "id", nothing) == source.id || return nothing
    copyencrypted!(item, get(item, "encrypted_content", nothing), source.encrypted)
end
copyencrypted!(item, current, encrypted) = nothing
copyencrypted!(item, ::Nothing, ::Nothing) = nothing
copyencrypted!(item, ::Nothing, encrypted) = (item["encrypted_content"] = encrypted; nothing)

emitusage(callback, ::Nothing) = nothing
emitusage(callback, usage) = callback((; type=:usage, usage))
emitfinish(callback, ::Nothing) = nothing
emitfinish(callback, reason) = callback((; type=:finish, reason))

reconcile!(state::ResponseStream, data, failure::InvalidResponse) = failure
reconcile!(state::ResponseStream, data, failure) = reconcile!(state, data, failure, responsestatus(get(data, "status", nothing)))
reconcile!(state::ResponseStream, data, failure, ::Unfinished) = failure

function reconcile!(state::ResponseStream, data, failure, ::Finished)
    !isempty(state.active) && (failure = "Responses stream contained an unfinished function call")
    for (index, item) in enumerate(data["output"])
        type = get(outputtypes, get(item, "type", nothing), nothing)
        failure = reconcile_item(state, index, item, failure, type)
    end
    for (index, item) in state.finished
        type = get(outputtypes, get(item, "type", nothing), nothing)
        failure = reconcile_done(data, index, failure, type)
    end
    failure
end

reconcile_item(state, index, item, failure, type) = failure
function reconcile_item(state, index, item, failure, ::Type{Conversation.ToolCall})
    reconcile_item(item, failure, get(state.finished, index - 1, nothing))
end

reconcile_item(item, failure, ::Nothing) = "Responses stream contained an unfinished or mismatched function call"
function reconcile_item(item, failure, done)
    any(key -> get(item, key, nothing) != get(done, key, nothing), ("id", "call_id", "name", "arguments")) && return "Responses stream contained an unfinished or mismatched function call"
    failure
end

reconcile_done(data, index, failure, type) = failure
function reconcile_done(data, index, failure, ::Type{Conversation.ToolCall})
    index >= length(data["output"]) && return "Responses stream omitted a completed function call"
    item = data["output"][index + 1]
    reconcile_done(failure, get(outputtypes, get(item, "type", nothing), nothing))
end
reconcile_done(failure, type) = "Responses stream omitted a completed function call"
reconcile_done(failure, ::Type{Conversation.ToolCall}) = failure
