module GoogleAPI

using HTTP, JSON3, Random, SHA
import ..JuliaForever: requestcontext, complete, stream, payload, headers, mergeheaders, endpoint, definition, decode, incomplete, InvalidResponse, ProviderStatus, ProviderError, providererror, protocolfield, Completion, Finished, Unfinished, Usage, DirectRoute, CatalogRoute, price, priceevent

struct Google
    base::String
    model::String
    key::String
    extra::Vector{Pair{String, String}}
    route::Union{DirectRoute, CatalogRoute}
    thinking::Union{Nothing, String}
end
Google(base, model, key, extra, route) = Google(base, model, key, extra, route, nothing)
Google(base, model, key) = Google(base, model, key, Pair{String, String}[], DirectRoute())
Google(base, model, key, extra) = Google(base, model, key, extra, DirectRoute())

Base.show(io::IO, provider::Google) = print(io, "Google(", repr(provider.model), ", [redacted])")
JSON3.StructTypes.StructType(::Type{Google}) = JSON3.StructTypes.CustomStruct()
JSON3.StructTypes.lower(provider::Google) = (; model=provider.model, credentials="[redacted]")
headers(provider::Google) = mergeheaders(["x-goog-api-key" => provider.key, "content-type" => "application/json"], provider.extra)
endpoint(provider::Google) = "$(rstrip(provider.base, '/'))/models/$(HTTP.escapeuri(provider.model)):generateContent"
endpoint(provider::Google, ::typeof(stream)) = "$(rstrip(provider.base, '/'))/models/$(HTTP.escapeuri(provider.model)):streamGenerateContent?alt=sse"
origin(provider::Google) = bytes2hex(sha256(provider.base)) * ":" * provider.model

abstract type Message end
struct System <: Message
    data
end
struct User <: Message
    data
end
struct Assistant <: Message
    data
end
struct Tool <: Message
    data
end
const messages = Dict("system" => System, "user" => User, "assistant" => Assistant, "tool" => Tool)

abstract type CallIds end
struct WithIds <: CallIds end
struct WithoutIds <: CallIds end
const idmodes = Dict(false => WithoutIds(), true => WithIds())
callids(model) = callids(model, match(r"^gemini(?:-live)?-(\d+)"i, model))
callids(model, ::Nothing) = idmodes[startswith(model, "claude-") || startswith(model, "gpt-oss-")]
callids(model, version::RegexMatch) = idmodes[parse(Int, version.captures[1]) >= 3]

abstract type ImageMode end
struct InlineImage <: ImageMode end
struct SeparateImage <: ImageMode end
const imagemodes = Dict(false => SeparateImage(), true => InlineImage())
imagemode(model) = imagemode(match(r"^gemini(?:-live)?-(\d+)"i, model))
imagemode(::Nothing) = InlineImage()
imagemode(version::RegexMatch) = imagemodes[parse(Int, version.captures[1]) >= 3]

mutable struct Transcript
    system::Vector{String}
    contents::Vector{Any}
    results::Vector{Any}
    calls::Dict{String, String}
    origin::String
    ids::CallIds
    image::ImageMode
end
Transcript(provider::Google) = Transcript(String[], [], [], Dict{String, String}(), origin(provider), callids(provider.model), imagemode(provider.model))

function flush!(transcript::Transcript)
    isempty(transcript.results) || push!(transcript.contents, Dict("role" => "user", "parts" => copy(transcript.results)))
    empty!(transcript.results)
end
function add!(transcript::Transcript, message::System)
    flush!(transcript)
    push!(transcript.system, message.data["content"])
end
function add!(transcript::Transcript, message::User)
    flush!(transcript)
    push!(transcript.contents, Dict("role" => "user", "parts" => userparts(message.data, get(message.data, "images", nothing))))
end
userparts(data, ::Nothing) = [Dict("text" => data["content"])]
imagepart(image) = Dict("inlineData" => Dict("mimeType" => image["mime"], "data" => image["data"]))
function userparts(data, attachments::AbstractVector)
    [Dict("text" => data["content"]), imagepart.(attachments)...]
end

function add!(transcript::Transcript, message::Assistant)
    flush!(transcript)
    data = message.data
    for call in get(data, "tool_calls", [])
        transcript.calls[call["id"]] = call["function"]["name"]
    end
    parts = get(data, "google_parts", nothing)
    if get(data, "google_origin", "") != transcript.origin
        parts = nothing
    end
    add!(transcript, data, parts)
end
function add!(transcript::Transcript, data, ::Nothing)
    parts = []
    addtext!(parts, get(data, "content", nothing))
    for call in get(data, "tool_calls", [])
        fn = call["function"]
        result = Dict("name" => fn["name"], "args" => JSON3.read(codeunits(fn["arguments"]), Dict{String, Any}))
        callid!(result, call["id"], transcript.ids)
        push!(parts, Dict("functionCall" => result))
    end
    add!(transcript, data, parts)
end
addtext!(parts, ::Nothing) = nothing
addtext!(parts, text) = push!(parts, Dict("text" => text))
function add!(transcript::Transcript, data, parts)
    restored = replay(parts, get(data, "tool_calls", []), transcript.ids)
    isempty(restored) || push!(transcript.contents, Dict("role" => "model", "parts" => restored))
end
const outputkeys = Dict(false => "output", true => "error")
function add!(transcript::Transcript, message::Tool)
    data = message.data
    id = data["tool_call_id"]
    name = transcript.calls[id]
    image = get(data, "image", nothing)
    output = Dict(outputkeys[get(data, "is_error", false)] => outputtext(data["content"], image))
    result = Dict("name" => name, "response" => output)
    callid!(result, id, transcript.ids)
    resultimage!(transcript, result, image)
end
outputtext(text, ::Nothing) = text
outputtext(text, image) = isempty(strip(text)) ? "(see attached image)" : text
function resultimage!(transcript, result, ::Nothing)
    push!(transcript.results, Dict("functionResponse" => result))
end
resultimage!(transcript, result, image) = resultimage!(transcript, result, image, transcript.image)
function resultimage!(transcript, result, image, ::InlineImage)
    result["parts"] = [imagepart(image)]
    push!(transcript.results, Dict("functionResponse" => result))
end
function resultimage!(transcript, result, image, ::SeparateImage)
    push!(transcript.results, Dict("functionResponse" => result))
    flush!(transcript)
    push!(transcript.contents, Dict("role" => "user", "parts" => [Dict("text" => "Tool result image:"), imagepart(image)]))
end

function payload(provider::Google, input, tools, parameters; streaming=false)
    transcript = Transcript(provider)
    for message in input
        data = Dict{String, Any}(string(key) => value for (key, value) in pairs(message))
        add!(transcript, messages[data["role"]](data))
    end
    flush!(transcript)
    data = Dict{String, Any}(string(key) => value for (key, value) in pairs(parameters))
    thinking!(data, provider.thinking, provider.model)
    data["contents"] = transcript.contents
    isempty(transcript.system) || (data["systemInstruction"] = Dict("parts" => [Dict("text" => join(transcript.system, "\n\n"))]))
    delete!(data, "tools")
    if !isempty(tools)
        data["tools"] = [Dict("functionDeclarations" => [Dict("name" => fn["name"], "description" => fn["description"], "parametersJsonSchema" => fn["parameters"]) for fn in (definition(tool)["function"] for tool in values(tools))])]
    end
    JSON3.write(data)
end

thinking!(data, ::Nothing, model) = nothing
function thinking!(data, level::AbstractString, model)
    generation = Dict{String, Any}(string(key) => value for (key, value) in pairs(get(data, "generationConfig", NamedTuple())))
    generation["thinkingConfig"] = thinkingconfig(model, level)
    data["generationConfig"] = generation
end
const budgets = Dict(
    "gemini-2.5-pro" => Dict("minimal" => 128, "low" => 2048, "medium" => 8192, "high" => 32768),
    "gemini-2.5-flash" => Dict("minimal" => 128, "low" => 2048, "medium" => 8192, "high" => 24576),
    "gemini-2.5-flash-lite" => Dict("minimal" => 512, "low" => 2048, "medium" => 8192, "high" => 24576),
    "gemini-2.5-computer-use-preview-10-2025" => Dict(level => -1 for level in ("minimal", "low", "medium", "high")),
)
thinkingconfig(model, level) = thinkingconfig(level, get(budgets, model, nothing))
thinkingconfig(level, ::Nothing) = Dict("includeThoughts" => true, "thinkingLevel" => uppercase(level))
thinkingconfig(level, budgets::AbstractDict) = budgetconfig(get(budgets, level, nothing))
budgetconfig(::Nothing) = Dict("thinkingBudget" => 0)
budgetconfig(budget::Int) = Dict("includeThoughts" => true, "thinkingBudget" => budget)

function usage(data::AbstractDict)
    input = something(get(data, "promptTokenCount", nothing), 0)
    cached = something(get(data, "cachedContentTokenCount", nothing), 0)
    reasoning = something(get(data, "thoughtsTokenCount", nothing), 0)
    output = something(get(data, "candidatesTokenCount", nothing), 0) + reasoning
    total = something(get(data, "totalTokenCount", nothing), input + output)
    Usage(max(0, input - cached), output, cached, 0, reasoning, total, nothing)
end
usage(::Nothing) = nothing

abstract type Part end
struct Text <: Part
    data
end
struct Thinking <: Part
    data
end
struct Call <: Part
    data
end
struct Unknown <: Part
    data
end
const texts = Dict(false => Text, true => Thinking)
callid!(data, id, ::WithIds) = (data["id"] = id)
callid!(data, id, ::WithoutIds) = delete!(data, "id")

function replay(parts, calls, mode::CallIds)
    index = Ref(0)
    [replay(part(data), calls, index, mode) for data in parts]
end
replay(part::Part, calls, index, mode) = part.data
function replay(part::Call, calls, index, mode)
    index[] += 1
    data = deepcopy(Dict{String, Any}(part.data))
    call = Dict{String, Any}(data["functionCall"])
    callid!(call, calls[index[]]["id"], mode)
    data["functionCall"] = call
    data
end

part(data) = part(data, get(data, "functionCall", nothing))
part(data, call::AbstractDict) = Call(data)
part(data, ::Nothing) = textpart(data, get(data, "text", nothing))
textpart(data, ::Nothing) = Unknown(data)
textpart(data, text) = get(texts, get(data, "thought", false), Unknown)(data)

mutable struct State
    parts::Vector{Any}
    calls::Vector{Any}
    text::Union{Nothing, String}
    used::Union{Nothing, Usage}
    reason::Union{Nothing, String}
    failure::Union{Nothing, String, InvalidResponse, ProviderError}
end
State() = State([], [], nothing, nothing, nothing, nothing)

add!(state::State, part::Unknown, callback) = (state.failure = "Google response contained an unsupported content part")
function add!(state::State, part::Text, callback)
    push!(state.parts, part.data)
    text = part.data["text"]
    add!(state, text, state.text)
    callback((; type=:text, text))
end
add!(state::State, text::AbstractString, ::Nothing) = (state.text = text)
add!(state::State, text::AbstractString, previous::AbstractString) = (state.text = previous * text)
function add!(state::State, part::Thinking, callback)
    push!(state.parts, part.data)
    text = part.data["text"]
    callback((; type=:thinking, text, field="thought"))
end
function add!(state::State, part::Call, callback)
    push!(state.parts, part.data)
    call = part.data["functionCall"]
    id = get(call, "id", nothing)
    id = callid(state, id)
    name = get(call, "name", "")
    arguments = JSON3.write(get(call, "args", Dict()))
    push!(state.calls, Dict("id" => id, "type" => "function", "function" => Dict("name" => name, "arguments" => arguments)))
    index = length(state.calls) - 1
    callback((; type=:tool_call, index, id, name, arguments))
end
callid(state, ::Nothing) = randstring(24)
function callid(state, id::AbstractString)
    isempty(id) && return randstring(24)
    ids = [call["id"] for call in state.calls]
    id in ids ? randstring(24) : id
end

function receive!(state::State, data::AbstractDict, callback)
    receive!(state, state.failure, data, callback)
end
function receive!(state::State, ::Nothing, data::AbstractDict, callback)
    callback((; type=:provider, data))
    receiveusage!(state, get(data, "usageMetadata", nothing), callback)
    candidates = get(data, "candidates", [])
    isempty(candidates) || receivecandidate!(state, first(candidates), callback)
    receiveerror!(state, protocolfield(data, "error"))
end
receiveerror!(state, ::Nothing) = nothing
receiveerror!(state, error::Some) = (state.failure = providererror(:google, something(error)))
receive!(state::State, failure, data::AbstractDict, callback) = nothing
receive!(state::State, failure::InvalidResponse, callback) = fail!(state, state.failure, failure)
fail!(state, ::Nothing, failure) = (state.failure = failure)
fail!(state, previous, failure) = nothing
receiveusage!(state, ::Nothing, callback) = nothing
function receiveusage!(state, data, callback)
    state.used = usage(data)
    callback((; type=:usage, usage=state.used))
end
function receivecandidate!(state, candidate, callback)
    content = something(get(candidate, "content", nothing), Dict())
    for data in get(content, "parts", [])
        add!(state, part(data), callback)
    end
    state.reason = get(candidate, "finishReason", state.reason)
    reportfinish!(callback, state.reason, state.calls)
end
reportfinish!(callback, ::Nothing, calls) = nothing
const finishreasons = merge(Dict("STOP" => "stop", "MAX_TOKENS" => "length"), Dict(reason => reason for reason in ("FINISH_REASON_UNSPECIFIED", "SAFETY", "RECITATION", "LANGUAGE", "OTHER", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "MALFORMED_FUNCTION_CALL", "IMAGE_SAFETY", "IMAGE_PROHIBITED_CONTENT", "IMAGE_OTHER", "NO_IMAGE", "IMAGE_RECITATION", "UNEXPECTED_TOOL_CALL", "TOO_MANY_TOOL_CALLS", "MISSING_THOUGHT_SIGNATURE", "MALFORMED_RESPONSE", "ESCALATION", "PUP_LIMITED_DISABLED", "CONTINUATION")))
abstract type Finish end
struct Stop <: Finish end
struct Limit <: Finish end
struct Other <: Finish
    reason
end
const finishes = Dict("STOP" => Stop(), "MAX_TOKENS" => Limit())
finish(reason) = get(finishes, reason, Other(reason))
finishname(::Stop, calls) = isempty(calls) ? "stop" : "tool_calls"
finishname(::Limit, calls) = "length"
finishname(other::Other, calls) = get(finishreasons, other.reason, nothing)

reportfinish!(callback, reason, calls) = reportknownfinish!(callback, finishname(finish(reason), calls))
reportknownfinish!(callback, ::Nothing) = nothing
function reportknownfinish!(callback, name::String)
    callback((; type=:finish, reason=name))
end

function finish(state::State, provider::Google)
    message = Dict{String, Any}("role" => "assistant", "content" => state.text, "google_parts" => state.parts, "google_origin" => origin(provider))
    isempty(state.calls) || (message["tool_calls"] = state.calls)
    result(message, state, state.reason)
end
function result(message, state, ::Nothing)
    Completion(message, state.used, nothing, Unfinished(), something(state.failure, "Google stream ended without a finish reason"))
end
function result(message, state, reason::AbstractString)
    result(message, state, reason, finish(reason))
end
function result(message, state, reason, ::Other)
    Completion(message, state.used, nothing, Unfinished(), something(state.failure, providererror(:google, reason)))
end
function result(message, state, reason, mapped::Union{Stop, Limit})
    outcome(message, state, finishname(mapped, state.calls), state.failure)
end
outcome(message, state, finish, ::Nothing) = Completion(message, state.used, finish, Finished(), nothing)
outcome(message, state, finish, failure) = Completion(message, state.used, finish, Unfinished(), failure)

httpfailure(status) = incomplete(ProviderStatus(status))

requestcontext(::Google) = HTTP.RequestContext()

function complete(provider::Google, input, tools; parameters=Dict())
    complete(provider, payload(provider, input, tools, parameters))
end
function complete(provider::Google, body::AbstractString)
    response = HTTP.post(endpoint(provider), headers(provider), body; redirect=false, retry=false, cookies=false, status_exception=false, context=requestcontext())
    200 <= response.status < 300 || return httpfailure(response.status)
    state = State()
    receive!(state, decode(String(response.body)), identity)
    price(provider, finish(state, provider))
end
function stream(provider::Google, input, tools; parameters=Dict(), on_event=identity)
    stream(provider, payload(provider, input, tools, parameters; streaming=true), on_event)
end
function stream(provider::Google, body::AbstractString, on_event)
    callback = event -> on_event(priceevent(provider, event))
    state = State()
    response = HTTP.post(endpoint(provider, stream), headers(provider), body; redirect=false, retry=false, cookies=false, status_exception=false, context=requestcontext(), sse_callback=raw -> receive!(state, decode(raw.data), callback))
    if !(200 <= response.status < 300)
        answer = httpfailure(response.status)
        callback((; type=:incomplete, result=answer))
        return answer
    end
    answer = price(provider, finish(state, provider))
    report!(callback, answer, answer.error)
    answer
end
report!(callback, answer, ::Nothing) = callback((; type=:done, result=answer))
report!(callback, answer, failure) = callback((; type=:incomplete, result=answer))

end

using .GoogleAPI: Google
