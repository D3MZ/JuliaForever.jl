module AnthropicAPI

using HTTP, JSON3, SHA
import ..JuliaForever: requestcontext, complete, stream, payload, headers, mergeheaders, endpoint, provider, definition, decode, incomplete, InvalidResponse, ProviderStatus, ProviderError, providererror, Completion, Finished, Unfinished, Usage, DirectRoute, CatalogRoute, Models, contextkey, price, priceevent
import ..Conversation

abstract type ThinkingMode end
struct DefaultThinking <: ThinkingMode end
struct BudgetThinking <: ThinkingMode
    level::String
    budget::Int
end
struct OffThinking <: ThinkingMode end

abstract type ToolStreaming end
struct Automatic <: ToolStreaming end
struct Eager <: ToolStreaming end
struct Legacy <: ToolStreaming end
struct Unspecified <: ToolStreaming end
const streamingmodes = Dict(true => Eager(), false => Legacy())
const catalogmodels = Set((model.provider, model.api, model.id) for model in Models.catalog())
const defaultstreaming = Dict(("https://api.anthropic.com", true) => Eager())
toolstreaming(::Nothing) = Automatic()
toolstreaming(value::Bool) = streamingmodes[value]

struct Anthropic
    base::String
    model::String
    key::String
    extra::Vector{Pair{String, String}}
    route::Union{DirectRoute, CatalogRoute}
    thinking::ThinkingMode
    toolstreaming::ToolStreaming
end
Anthropic(base, model, key; eager_tool_streaming=nothing) = Anthropic(base, model, key, Pair{String, String}[], DirectRoute(); eager_tool_streaming)
Anthropic(base, model, key, extra; eager_tool_streaming=nothing) = Anthropic(base, model, key, extra, DirectRoute(); eager_tool_streaming)
Anthropic(base, model, key, extra, route; eager_tool_streaming=nothing) = Anthropic(base, model, key, extra, route, DefaultThinking(), toolstreaming(eager_tool_streaming))
Anthropic(base, model, key, extra, route, thinking::ThinkingMode) = Anthropic(base, model, key, extra, route, thinking, Automatic())
effectivestreaming(provider::Anthropic) = effectivestreaming(provider.toolstreaming, provider)
effectivestreaming(mode::ToolStreaming, provider) = mode
effectivestreaming(::Automatic, provider) = get(defaultstreaming, (rstrip(provider.base, '/'), ("anthropic", "anthropic-messages", provider.model) in catalogmodels), Unspecified())

Base.show(io::IO, provider::Anthropic) = print(io, "Anthropic(", repr(provider.model), ", [redacted])")
JSON3.StructTypes.StructType(::Type{Anthropic}) = JSON3.StructTypes.CustomStruct()
JSON3.StructTypes.lower(provider::Anthropic) = (; model=provider.model, credentials="[redacted]")
thinkingbetas(::ThinkingMode) = String[]
thinkingbetas(::BudgetThinking) = ["interleaved-thinking-2025-05-14"]
toolbetas(::ToolStreaming, tools) = String[]
const legacybetas = Dict(true => String[], false => ["fine-grained-tool-streaming-2025-05-14"])
toolbetas(::Legacy, tools) = legacybetas[isempty(tools)]
betaheaders(betas) = isempty(betas) ? Pair{String, String}[] : ["anthropic-beta" => join(betas, ",")]
headers(provider::Anthropic) = headers(provider, ())
function headers(provider::Anthropic, tools)
    betas = [toolbetas(effectivestreaming(provider), tools); thinkingbetas(provider.thinking)]
    mergeheaders(vcat(isempty(provider.key) ? Pair{String, String}[] : ["x-api-key" => provider.key], ["anthropic-version" => "2023-06-01", "content-type" => "application/json"], betaheaders(betas)), provider.extra)
end
toolfields(::ToolStreaming) = Dict{String, Any}()
toolfields(::Eager) = Dict{String, Any}("eager_input_streaming" => true)
endpoint(provider::Anthropic) = "$(rstrip(provider.base, '/'))/v1/messages"
origin(provider::Anthropic) = bytes2hex(sha256(provider.base)) * ":" * provider.model

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

mutable struct Transcript
    system::Vector{String}
    messages::Vector{Any}
    tools::Vector{Any}
    attachments::Vector{Any}
    calls::Dict{String, String}
    origin::String
end
Transcript(provider::Anthropic) = Transcript(String[], [], [], [], Dict{String, String}(), origin(provider))

function flush!(transcript::Transcript)
    isempty(transcript.tools) || push!(transcript.messages, Dict("role" => "user", "content" => [transcript.tools; transcript.attachments]))
    empty!(transcript.tools)
    empty!(transcript.attachments)
end

function add!(transcript::Transcript, message::System)
    flush!(transcript)
    push!(transcript.system, message.data["content"])
end

function add!(transcript::Transcript, message::User)
    flush!(transcript)
    push!(transcript.messages, Dict("role" => "user", "content" => usercontent(message.data, get(message.data, "images", nothing))))
end

usercontent(data, ::Nothing) = data["content"]
imageblock(image) = Dict("type" => "image", "source" => Dict("type" => "base64", "media_type" => image["mime"], "data" => image["data"]))
function usercontent(data, attachments::AbstractVector)
    [Dict("type" => "text", "text" => data["content"]), imageblock.(attachments)...]
end

function add!(transcript::Transcript, message::Assistant)
    flush!(transcript)
    data = message.data
    for call in get(data, "tool_calls", [])
        transcript.calls[call["id"]] = call["function"]["name"]
    end
    blocks = get(data, "anthropic_content", nothing)
    if get(data, "anthropic_origin", "") != transcript.origin
        blocks = nothing
    end
    add!(transcript, data, blocks)
end

function add!(transcript::Transcript, data, ::Nothing)
    blocks = []
    text = get(data, "content", nothing)
    appendtext!(blocks, text)
    for call in get(data, "tool_calls", [])
        fn = call["function"]
        push!(blocks, Dict("type" => "tool_use", "id" => call["id"], "name" => fn["name"], "input" => JSON3.read(codeunits(fn["arguments"]), Dict{String, Any})))
    end
    add!(transcript, data, blocks)
end

appendtext!(blocks, ::Nothing) = nothing
appendtext!(blocks, text) = push!(blocks, Dict("type" => "text", "text" => text))
function add!(transcript::Transcript, data, blocks)
    isempty(blocks) || push!(transcript.messages, Dict("role" => "assistant", "content" => blocks))
end

function add!(transcript::Transcript, message::Tool)
    data = message.data
    content = toolcontent!(transcript, data, get(data, "image", nothing))
    push!(transcript.tools, Dict("type" => "tool_result", "tool_use_id" => data["tool_call_id"], "content" => content, "is_error" => get(data, "is_error", false)))
end

abstract type ToolImage end
struct SuccessImage <: ToolImage end
struct ErrorImage <: ToolImage end
const toolimages = Dict(false => SuccessImage(), true => ErrorImage())
toolcontent!(transcript, data, ::Nothing) = data["content"]
toolcontent!(transcript, data, image) = toolcontent!(transcript, data, image, toolimages[get(data, "is_error", false)])
toolcontent!(transcript, data, image, ::SuccessImage) = [Dict("type" => "text", "text" => data["content"]), imageblock(image)]
function toolcontent!(transcript, data, image, ::ErrorImage)
    id = data["tool_call_id"]
    name = transcript.calls[id]
    push!(transcript.attachments, Dict("type" => "text", "text" => "Images from the error result of tool call $id ($name):"), imageblock(image))
    data["content"] * "\n(image attached after the tool results)"
end

function payload(provider::Anthropic, input, tools, parameters; streaming=false)
    transcript = Transcript(provider)
    for message in input
        data = Dict{String, Any}(string(key) => value for (key, value) in pairs(message))
        add!(transcript, messages[data["role"]](data))
    end
    flush!(transcript)
    data = Dict{String, Any}(string(key) => value for (key, value) in pairs(parameters))
    data["model"] = provider.model
    data["messages"] = transcript.messages
    data["stream"] = streaming
    thinking!(data, provider.thinking, input, tools, provider)
    isempty(transcript.system) || (data["system"] = join(transcript.system, "\n\n"))
    delete!(data, "tools")
    if !isempty(tools)
        fields = toolfields(effectivestreaming(provider))
        data["tools"] = [merge(Dict("name" => fn["name"], "description" => fn["description"], "input_schema" => fn["parameters"]), fields) for fn in (definition(tool)["function"] for tool in values(tools))]
    end
    JSON3.write(data)
end

thinking!(data, ::DefaultThinking, input, tools, provider) = get!(data, "max_tokens", 4096)
function thinking!(data, ::OffThinking, input, tools, provider)
    data["max_tokens"] = min(get(data, "max_tokens", 64000), ceiling(input, tools, provider))
    data["thinking"] = Dict("type" => "disabled")
end
function thinking!(data, mode::BudgetThinking, input, tools, provider)
    limit = ceiling(input, tools, provider)
    base = min(get(data, "max_tokens", 64000), limit)
    maximum = min(base + mode.budget, 64000, limit)
    budget = min(mode.budget, max(0, maximum - 1024))
    data["max_tokens"] = maximum
    data["thinking"] = Dict("type" => "enabled", "budget_tokens" => iszero(budget) ? 1024 : budget, "display" => "summarized")
    delete!(data, "temperature")
end
function ceiling(input, tools, provider)
    estimates = parentmodule(@__MODULE__).ContextEstimates
    messages = [Conversation.RawMessage(Dict{String, Any}(string(key) => value for (key, value) in pairs(message))) for message in input]
    anchor = contextanchor(input, get(task_local_storage(), contextkey, nothing))
    max(1, 200000 - contextestimate(estimates, messages, tools, anchor, provider) - 4096)
end

struct ContextAnchor
    index::Int
    usage::Usage
    tools::String
end
contextestimate(estimates, messages, tools, ::Nothing, provider) = estimates.estimate(messages; tools=values(tools)).total
function contextestimate(estimates, messages, tools, anchor::ContextAnchor, provider)
    measured = estimates.estimate(messages, anchor.index => anchor.usage).total
    # A changed tool set may add context not covered by the reported usage.
    measured + (anchor.tools == tooldigest(provider, tools) ? 0 : estimates.declared(values(tools)))
end

const contextfields = ("role", "content", "images", "tool_calls", "tool_call_id", "is_error", "image", "anthropic_content", "anthropic_origin", "reasoning_content", "reasoning", "reasoning_text", "sections", "toolsAdded", "toolsRemoved")
canonical(value) = value
canonical(value::NamedTuple) = canonical(Dict(pairs(value)))
canonical(value::Tuple) = map(canonical, value)
canonical(value::AbstractVector) = map(canonical, value)
function canonical(value::AbstractDict)
    fields = sort!(collect(pairs(value)); by=pair -> string(first(pair)))
    [(string(key), canonical(item)) for (key, item) in fields]
end
function contextmessage(message)
    data = Dict{String, Any}(string(key) => value for (key, value) in pairs(message))
    [(key, canonical(get(data, key, nothing))) for key in contextfields]
end
digest(text::AbstractString) = bytes2hex(sha256(Vector{UInt8}(codeunits(text))))
contextdigest(input::AbstractVector) = digest(JSON3.write(contextmessage.(input)))
function tooldigest(provider, tools)
    fields = toolfields(effectivestreaming(provider))
    definitions = [merge(definition(tool)["function"], fields) for tool in values(tools)]
    sort!(definitions; by=tool -> tool["name"])
    digest(JSON3.write(canonical(definitions)))
end

# Only native assistant messages can supply a recorded measurement.
messageanchor(message::Conversation.Message) = nothing
messageanchor(message::Conversation.Assistant) = get(message.metadata, "anthropic_usage_anchor", nothing)
lastanchor(previous, index, value) = previous
lastanchor(previous, index, value::AbstractDict) = index
contextanchor(input, ::Nothing) = nothing
function contextanchor(input, messages::AbstractVector)
    last = foldl(1:min(length(input), length(messages)); init=nothing) do previous, index
        lastanchor(previous, index, messageanchor(messages[index]))
    end
    prefixanchor(input, messages, last)
end
prefixanchor(input, messages, ::Nothing) = nothing
function prefixanchor(input, messages, last::Int)
    ctx = SHA2_256_CTX()
    SHA.update!(ctx, UInt8[0x5b])
    selected = nothing
    for index in 1:last
        index > 1 && SHA.update!(ctx, UInt8[0x2c])
        SHA.update!(ctx, Vector{UInt8}(codeunits(JSON3.write(contextmessage(input[index])))))
        selected = selectanchor(selected, index, ctx, messageanchor(messages[index]))
    end
    selected
end
selectanchor(previous, index, ctx, value) = previous
selectanchor(previous, index, ctx, value::AbstractDict) = selectanchor(previous, index, ctx, get(value, "tokens", nothing), get(value, "digest", nothing), get(value, "tools", nothing))
selectanchor(previous, index, ctx, tokens, expected, toolhash) = previous
function selectanchor(previous, index, ctx, tokens::Int, expected::AbstractString, toolhash::AbstractString)
    tokens > 0 && expected == prefixdigest(ctx) || return previous
    ContextAnchor(index, Usage(tokens, 0, 0, 0, 0, tokens, nothing), toolhash)
end
function prefixdigest(ctx::SHA2_256_CTX)
    snapshot = copy(ctx)
    SHA.update!(snapshot, UInt8[0x5d])
    bytes2hex(SHA.digest!(snapshot))
end

remembercontext!(answer, input, tools, provider) = remembercontext!(answer, input, tools, provider, get(task_local_storage(), contextkey, nothing), getfield(answer, :status), answer.usage)
remembercontext!(answer, input, tools, provider, context, status, usage) = answer
function remembercontext!(answer, input, tools, provider, context::AbstractVector, ::Finished, usage::Usage)
    tokens = parentmodule(@__MODULE__).ContextEstimates.reported(usage)
    tokens > 0 && (answer.message["anthropic_usage_anchor"] = Dict("tokens" => tokens, "digest" => contextdigest([input; [answer.message]]), "tools" => tooldigest(provider, tools)))
    answer
end

function usage(data::AbstractDict)
    input = something(get(data, "input_tokens", nothing), 0)
    output = something(get(data, "output_tokens", nothing), 0)
    read = something(get(data, "cache_read_input_tokens", nothing), 0)
    write = something(get(data, "cache_creation_input_tokens", nothing), 0)
    details = something(get(data, "output_tokens_details", nothing), Dict())
    reasoning = get(details, "thinking_tokens", 0)
    cache = something(get(data, "cache_creation", nothing), Dict())
    longwrite = something(get(cache, "ephemeral_1h_input_tokens", nothing), 0)
    Usage(input, output, read, write, reasoning, input + output + read + write, nothing, nothing, longwrite)
end
usage(::Nothing) = nothing

abstract type Finish end
struct End <: Finish end
struct Limit <: Finish end
struct ToolUse <: Finish end
const finishes = Dict("end_turn" => End(), "stop_sequence" => End(), "pause_turn" => End(), "max_tokens" => Limit(), "tool_use" => ToolUse())
finish(::Nothing) = nothing
finish(reason) = get(finishes, reason, nothing)
finishname(::End) = "stop"
finishname(::Limit) = "length"
finishname(::ToolUse) = "tool_calls"

abstract type Block end
struct Text <: Block
    data::Dict{String, Any}
end
struct Thinking <: Block
    data::Dict{String, Any}
end
struct Redacted <: Block
    data::Dict{String, Any}
end
mutable struct Call <: Block
    data::Dict{String, Any}
    arguments::String
end
struct Unknown <: Block
    data::Dict{String, Any}
end
Call(data) = Call(data, "")
const blocks = Dict("text" => Text, "thinking" => Thinking, "redacted_thinking" => Redacted, "tool_use" => Call)
block(data) = get(blocks, data["type"], Unknown)(Dict{String, Any}(data))

function content(blocks)
    message = Dict{String, Any}("role" => "assistant", "content" => nothing, "anthropic_content" => [block.data for block in blocks])
    calls = []
    for block in blocks
        add!(message, calls, block)
    end
    isempty(calls) || (message["tool_calls"] = calls)
    message
end
add!(message::AbstractDict, calls::AbstractVector, block::Block) = nothing
function add!(message::AbstractDict, calls::AbstractVector, block::Text)
    text = block.data["text"]
    appendtext!(message, text, message["content"])
end
appendtext!(message, text, ::Nothing) = (message["content"] = text)
appendtext!(message, text, current) = (message["content"] = current * text)
function add!(message::AbstractDict, calls::AbstractVector, block::Call)
    data = block.data
    push!(calls, Dict("id" => data["id"], "type" => "function", "function" => Dict("name" => data["name"], "arguments" => JSON3.write(data["input"]))))
end

const invalidcontent = "Anthropic response contained an unsupported or invalid content block"
blockfailures(blocks) = foldl(blockcheck, blocks; init=nothing)
blockcheck(detail::String, block) = detail
blockcheck(::Nothing, block::Block) = blockfailure(block)
blockfailure(::Block) = nothing
blockfailure(::Unknown) = invalidcontent
function blockfailure(block::Call)
    isempty(block.data["id"]) && return invalidcontent
    isempty(block.data["name"]) && return invalidcontent
    inputfailure(block.data["input"])
end
inputfailure(::AbstractDict) = nothing
inputfailure(input) = invalidcontent
ids!(ids, ::Block) = nothing
ids!(ids, call::Call) = push!(ids, call.data["id"])
function callids(blocks)
    ids = String[]
    foreach(block -> ids!(ids, block), blocks)
    ids
end
uniqueids(blocks) = allunique(callids(blocks))
consistent(blocks, ::Union{End, Limit}) = isempty(callids(blocks))
consistent(blocks, ::ToolUse) = !isempty(callids(blocks))

function result(blocks, reason, used, failure)
    mapped = finish(reason)
    result(blocks, reason, used, failure, mapped)
end

function result(blocks, reason, used, failure, ::Nothing)
    detail = providererror(:anthropic, reason)
    failure = something(failure, detail)
    Completion(content(blocks), used, nothing, Unfinished(), failure)
end

result(blocks, reason, used, failure, mapped::Finish) = checkedresult(blocks, used, failure, mapped, blockfailures(blocks))
checkedresult(blocks, used, failure, mapped, detail::String) = outcome(blocks, used, finishname(mapped), something(failure, detail))
function checkedresult(blocks, used, failure, mapped, ::Nothing)
    failure = uniqueids(blocks) && consistent(blocks, mapped) ? failure : something(failure, invalidcontent)
    outcome(blocks, used, finishname(mapped), failure)
end

outcome(blocks, used, mapped, ::Nothing) = Completion(content(blocks), used, mapped, Finished(), nothing)
outcome(blocks, used, mapped, failure) = Completion(content(blocks), used, mapped, Unfinished(), failure)

requestcontext(::Anthropic) = HTTP.RequestContext()

function complete(provider::Anthropic, input, tools; parameters=Dict())
    remembercontext!(complete(provider, payload(provider, input, tools, parameters), headers(provider, tools)), input, tools, provider)
end
function complete(provider::Anthropic, body::AbstractString, requestheaders=headers(provider))
    response = HTTP.post(endpoint(provider), requestheaders, body; redirect=false, retry=false, cookies=false, status_exception=false, context=requestcontext())
    200 <= response.status < 300 || return incomplete(ProviderStatus(response.status))
    price(provider, tagged(completion(decode(String(response.body))), provider))
end
incomplete(failure::String) = Completion(Dict{String, Any}("role" => "assistant", "content" => nothing), nothing, nothing, Unfinished(), failure)
tagged(answer::Completion, provider::Anthropic) = (answer.message["anthropic_origin"] = origin(provider); answer)
completion(failure::InvalidResponse) = incomplete(failure)
function completion(data::AbstractDict)
    result(block.(data["content"]), get(data, "stop_reason", nothing), usage(get(data, "usage", nothing)), nothing)
end

abstract type Event end
struct Start <: Event
    data
end
struct BlockStart <: Event
    data
end
struct BlockDelta <: Event
    data
end
struct BlockStop <: Event
    data
end
struct Delta <: Event
    data
end
struct Stop <: Event
    data
end
struct Failure <: Event
    data
end
struct Ignore <: Event
    data
end
const events = Dict("message_start" => Start, "content_block_start" => BlockStart, "content_block_delta" => BlockDelta, "content_block_stop" => BlockStop, "message_delta" => Delta, "message_stop" => Stop, "error" => Failure)
event(data) = get(events, get(data, "type", ""), Ignore)(data)

abstract type Phase end
struct Waiting <: Phase end
struct Running <: Phase end
struct Stopped <: Phase end

mutable struct State
    blocks::Vector{Block}
    open::Dict{Int, Block}
    seen::Set{Int}
    used::Dict{String, Any}
    reason::Union{Nothing, String}
    failure::Union{Nothing, String, InvalidResponse, ProviderError}
    phase::Phase
end
State() = State(Block[], Dict{Int, Block}(), Set{Int}(), Dict{String, Any}(), nothing, nothing, Waiting())

function receive!(state::State, ::Waiting, event::Start, callback)
    state.phase = Running()
    mergeusage!(state.used, get(event.data["message"], "usage", Dict()))
end

function mergeusage!(used, update)
    previous = get(used, "cache_creation", nothing)
    current = get(update, "cache_creation", nothing)
    merge!(used, update)
    mergecache!(used, previous, current)
    nothing
end
mergecache!(used, previous, current) = nothing
mergecache!(used, previous::AbstractDict, ::Nothing) = (used["cache_creation"] = previous; nothing)
function mergecache!(used, previous::AbstractDict, current::AbstractDict)
    values = merge(previous, current)
    retaincache!(values, get(previous, "ephemeral_1h_input_tokens", nothing), get(current, "ephemeral_1h_input_tokens", nothing))
    used["cache_creation"] = values
    nothing
end
retaincache!(values, previous, current) = nothing
retaincache!(values, previous::Integer, ::Nothing) = (values["ephemeral_1h_input_tokens"] = previous; nothing)

function receive!(state::State, ::Running, event::BlockStart, callback)
    index = event.data["index"]
    if index in state.seen
        state.failure = "Anthropic stream contained a duplicate content block"
        return
    end
    value = block(event.data["content_block"])
    push!(state.seen, index)
    push!(state.blocks, value)
    state.open[index] = value
    start!(value, index, callback)
end
start!(block::Block, index, callback) = nothing
function start!(block::Text, index, callback)
    text = block.data["text"]
    isempty(text) || callback((; type=:text, text))
end
function start!(block::Thinking, index, callback)
    text = block.data["thinking"]
    isempty(text) || callback((; type=:thinking, text, field="thinking"))
end
function start!(block::Call, index, callback)
    id = block.data["id"]
    name = block.data["name"]
    arguments = ""
    callback((; type=:tool_call, index, id, name, arguments))
end

abstract type Change end
struct TextDelta <: Change
    data
end
struct ThinkingDelta <: Change
    data
end
struct SignatureDelta <: Change
    data
end
struct InputDelta <: Change
    data
end
struct UnknownDelta <: Change
    data
end
const changes = Dict("text_delta" => TextDelta, "thinking_delta" => ThinkingDelta, "signature_delta" => SignatureDelta, "input_json_delta" => InputDelta)
change(data) = get(changes, data["type"], UnknownDelta)(data)

function receive!(state::State, ::Running, event::BlockDelta, callback)
    index = event.data["index"]
    apply!(state, get(state.open, index, nothing), change(event.data["delta"]), index, callback)
end
function apply!(state, block, change, index, callback)
    state.failure = "Anthropic stream contained an unexpected content delta"
end
function apply!(state, block::Text, change::TextDelta, index, callback)
    text = change.data["text"]
    block.data["text"] *= text
    callback((; type=:text, text))
end
function apply!(state, block::Thinking, change::ThinkingDelta, index, callback)
    text = change.data["thinking"]
    block.data["thinking"] *= text
    callback((; type=:thinking, text, field="thinking"))
end
function apply!(state, block::Thinking, change::SignatureDelta, index, callback)
    block.data["signature"] *= change.data["signature"]
end
function apply!(state, block::Call, change::InputDelta, index, callback)
    arguments = change.data["partial_json"]
    block.arguments *= arguments
    id = nothing
    name = nothing
    callback((; type=:tool_call, index, id, name, arguments))
end

function receive!(state::State, ::Running, event::BlockStop, callback)
    index = event.data["index"]
    block = pop!(state.open, index, nothing)
    close!(state, block)
end
close!(state, ::Nothing) = (state.failure = "Anthropic stream stopped an unknown content block")
close!(state, ::Block) = nothing
function close!(state, block::Call)
    isempty(block.arguments) && return
    close!(state, block, decode(block.arguments))
end
close!(state, block::Call, failure::InvalidResponse) = (state.failure = failure)
close!(state, block::Call, input::AbstractDict) = (block.data["input"] = input)

function receive!(state::State, ::Running, event::Delta, callback)
    state.reason = get(event.data["delta"], "stop_reason", state.reason)
    mergeusage!(state.used, get(event.data, "usage", Dict()))
    reported = usage(state.used)
    callback((; type=:usage, usage=reported))
    reason = finish(state.reason)
    report!(callback, reason)
end
report!(callback, ::Nothing) = nothing
report!(callback, reason::Finish) = callback((; type=:finish, reason=finishname(reason)))
receive!(state::State, ::Running, ::Stop, callback) = (state.phase = Stopped())
receive!(state::State, ::Phase, event::Failure, callback) = (state.failure = providererror(:anthropic, event.data["error"]))
receive!(state::State, ::Phase, ::Ignore, callback) = nothing
receive!(state::State, ::Phase, ::Event, callback) = (state.failure = "Anthropic stream contained an unexpected event")

function stream(provider::Anthropic, input, tools; parameters=Dict(), on_event=identity)
    remembercontext!(stream(provider, payload(provider, input, tools, parameters; streaming=true), on_event, headers(provider, tools)), input, tools, provider)
end
function stream(provider::Anthropic, body::AbstractString, on_event, requestheaders=headers(provider))
    callback = event -> on_event(priceevent(provider, event))
    state = State()
    response = HTTP.post(endpoint(provider), requestheaders, body; redirect=false, retry=false, cookies=false, status_exception=false, context=requestcontext(), sse_callback=raw -> receive!(state, decode(raw.data), callback))
    if !(200 <= response.status < 300)
        answer = incomplete(ProviderStatus(response.status))
        callback((; type=:incomplete, result=answer))
        return answer
    end
    price(provider, finish!(state, callback, provider))
end
receive!(state::State, failure::InvalidResponse, callback) = fail!(state, state.failure, failure)
fail!(state, ::Nothing, failure) = (state.failure = failure)
fail!(state, previous, failure) = nothing
receive!(state::State, data::AbstractDict, callback) = receive!(state, state.failure, data, callback)
function receive!(state::State, ::Nothing, data::AbstractDict, callback)
    on = event(data)
    callback((; type=:provider, data))
    receive!(state, state.phase, on, callback)
end
receive!(state::State, failure, data::AbstractDict, callback) = nothing

function finish!(state::State, callback, provider)
    failure = ended(state, state.phase)
    used = isempty(state.used) ? nothing : usage(state.used)
    answer = tagged(result(state.blocks, state.reason, used, failure), provider)
    report!(callback, answer, answer.error)
    answer
end
ended(state, ::Phase) = something(state.failure, "Anthropic stream ended before completion")
ended(state, ::Stopped) = isempty(state.open) ? state.failure : something(state.failure, "Anthropic stream ended before completion")
report!(callback, answer, ::Nothing) = callback((; type=:done, result=answer))
report!(callback, answer, failure) = callback((; type=:incomplete, result=answer))

end

using .AnthropicAPI: Anthropic
