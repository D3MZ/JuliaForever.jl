module LiveJSON

using JSON3, Dates, Random, SHA
import ..JuliaForever as J
import ..JuliaForever: Terminal, JSONMode, RPCMode, Agent, OpenAI, OpenAIResponses, Anthropic, Google, ManagedChatGPT, ChatGPT, UnconfiguredProvider, Usage, CostBreakdown, Completion, Finished, Unfinished, Truncated, History, SessionCatalog, Extensions, FileArguments, Prompts, Skills, Image, ToolResult, ToolFailure, ShellUpdate, PendingInputs, Unannounced, Announced, providercomplete!, run!, runmode!, starttemplates!, request!, respond!, failures!, result!, redact, attempt, fileinput, fileprompt, iserror, modelcatalogname

function write!(io, event)
    JSON3.write(io, event)
    write(io, '\n')
    flush(io)
    nothing
end

nowms() = round(Int, 1000time())
isotime() = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS.sss") * "Z"
id(::Nothing) = bytes2hex(rand(RandomDevice(), UInt8, 16))
id(::History.Memory) = id(nothing)
id(history::History.Tree) = id(history.store)
id(history::SessionCatalog.Deferred) = id(history.path)
id(history::History.SQLite) = id(SessionCatalog.path(history))
id(history::History.Store) = id(nothing)
id(path::AbstractString) = id(path, match(r"--([0-9a-f]{32})\.sqlite$", basename(path)))
id(path, found::RegexMatch) = String(found.captures[1])
id(path, ::Nothing) = bytes2hex(sha256(abspath(path)))[1:32]

function header!(terminal, history)
    write!(terminal.output, (; type="session", version=3, id=id(history), timestamp=isotime(), cwd=pwd()))
end

api(::OpenAI) = "openai-completions"
api(::OpenAIResponses) = "openai-responses"
api(::Anthropic) = "anthropic-messages"
api(::Google) = "google-generative-ai"
api(::Union{ManagedChatGPT, ChatGPT.Plan}) = "openai-responses"
api(::UnconfiguredProvider) = "unknown"
providername(mode::Union{JSONMode, RPCMode}, provider::OpenAIResponses) = modelcatalogname(provider, mode.provider)
providername(::RPCMode, ::UnconfiguredProvider) = "unknown"
providername(mode::Union{JSONMode, RPCMode}, provider) = mode.provider

usage(::Nothing) = (; input=0, output=0, cacheRead=0, cacheWrite=0, totalTokens=0, cost=(; input=0, output=0, cacheRead=0, cacheWrite=0, total=0))
function usage(value::Usage)
    base = (; input=value.input, output=value.output, cacheRead=value.cache_read, cacheWrite=value.cache_write, totalTokens=value.total, cost=usagecost(value, value.breakdown))
    base = iszero(value.reasoning) ? base : merge(base, (; reasoning=value.reasoning))
    iszero(value.cache_write_1h) ? base : merge(base, (; cacheWrite1h=value.cache_write_1h))
end
usagecost(value, ::Nothing) = usagecost(value.cost)
usagecost(::Nothing) = (; input=0, output=0, cacheRead=0, cacheWrite=0, total=0.0)
usagecost(value::Float64) = (; input=0, output=0, cacheRead=0, cacheWrite=0, total=value, totalFromProvider=true)
const costorigins = Dict{Any, Bool}(nothing => false)
usagecost(value, breakdown::CostBreakdown) = (; input=breakdown.input, output=breakdown.output, cacheRead=breakdown.cache_read, cacheWrite=breakdown.cache_write, total=something(value.cost, 0.0), totalFromProvider=get(costorigins, breakdown.reported, true))

abstract type Block end
function buffer(text::AbstractString)
    value = IOBuffer()
    write(value, text)
    value
end
buffertext(value::IOBuffer) = String(take!(copy(value)))
function settext!(value::IOBuffer, text)
    truncate(value, 0)
    seekstart(value)
    write(value, text)
    nothing
end
mutable struct TextBlock <: Block
    index::Int
    text::IOBuffer
end
mutable struct ThinkingBlock <: Block
    index::Int
    text::IOBuffer
end
TextBlock(index, text::AbstractString) = TextBlock(index, buffer(text))
ThinkingBlock(index, text::AbstractString) = ThinkingBlock(index, buffer(text))
abstract type CallState end
struct Unstarted <: CallState end
struct Started <: CallState end
mutable struct CallBlock <: Block
    index::Int
    id::String
    name::String
    arguments::IOBuffer
    pending::IOBuffer
    state::Union{Unstarted, Started}
end
CallBlock(index, id, name, arguments::AbstractString, pending::AbstractString, state::CallState) = CallBlock(index, id, name, buffer(arguments), buffer(pending), state)

abstract type WireActivity end
struct WireIdle <: WireActivity end
struct WireRunning <: WireActivity end
struct WireRetry <: WireActivity end

mutable struct Stream{I<:IO, T<:Terminal}
    io::I
    terminal::T
    api::String
    provider::String
    model::String
    used::Union{Nothing, Usage}
    completion::Union{Nothing, Completion}
    stamp::Int
    blocks::Vector{Union{TextBlock, ThinkingBlock, CallBlock}}
    active::Union{Nothing, TextBlock, ThinkingBlock}
    calls::Dict{Any, CallBlock}
    names::Dict{String, String}
    current::Dict{String, Any}
    assistant::Dict{String, Any}
    messages::Vector{Dict{String, Any}}
    results::Vector{Dict{String, Any}}
    initial::Vector{Dict{String, Any}}
    started::Union{Unannounced, Announced}
    ended::Union{Unannounced, Announced}
    turnended::Union{Unannounced, Announced}
    runended::Union{Unannounced, Announced}
    activity::WireActivity
end

function Stream(terminal, agent, mode)
    Stream(terminal.output, terminal, api(agent.provider), providername(mode, agent.provider), agent.provider.model, nothing, nothing, nowms(), Union{TextBlock, ThinkingBlock, CallBlock}[], nothing, Dict{Any, CallBlock}(), Dict{String, String}(), Dict{String, Any}(), Dict{String, Any}(), Dict{String, Any}[], Dict{String, Any}[], initialmessages(agent), Unannounced(), Unannounced(), Unannounced(), Unannounced(), WireIdle())
end

struct ProviderObserver{S}
    stream::S
end
(observer::ProviderObserver)(event) = provider!(observer.stream, event)
providercomplete!(observer::ProviderObserver, result::Completion) = complete!(observer.stream, result)
provider!(stream, event) = provider!(stream, get(providerevents, event.type, nothing), event)
provider!(stream, ::Nothing, event) = nothing
struct ReportedUsage end
struct Completed end
const providerevents = Dict(:usage => ReportedUsage(), :done => Completed(), :incomplete => Completed())
provider!(stream, ::ReportedUsage, event) = (stream.used = event.usage; nothing)
provider!(stream, ::Completed, event) = complete!(stream, event.result)
function complete!(stream, result)
    stream.completion = result
    setusage!(stream, result.usage)
end
setusage!(stream, ::Nothing) = nothing
setusage!(stream, used::Usage) = (stream.used = used; nothing)

abstract type Event end
struct AgentStart <: Event end
struct AgentEnd <: Event end
struct TurnStart <: Event end
struct TurnEnd <: Event end
struct MessageStart <: Event end
struct MessageUpdate <: Event end
struct MessageEnd <: Event end
struct ToolStart <: Event end
struct ToolUpdate <: Event end
struct ToolEnd <: Event end
struct CompactionStart <: Event end
struct CompactionEnd <: Event end
const events = Dict(:agent_start => AgentStart(), :agent_end => AgentEnd(), :turn_start => TurnStart(), :turn_end => TurnEnd(), :message_start => MessageStart(), :message_update => MessageUpdate(), :message_end => MessageEnd(), :tool_execution_start => ToolStart(), :tool_execution_update => ToolUpdate(), :tool_execution_end => ToolEnd(), :auto_compaction_start => CompactionStart(), :auto_compaction_end => CompactionEnd())

observe!(stream, event) = observe!(stream, get(events, event.type, nothing), event)
observe!(stream, ::Nothing, event) = nothing
function observe!(stream, ::AgentStart, event)
    empty!(stream.messages)
    stream.runended = Unannounced()
    stream.activity = WireRunning()
    write!(stream.io, (; type="agent_start"))
end
observe!(stream, ::AgentEnd, event) = agentended!(stream, stream.activity)
agentended!(stream, activity::WireActivity) = nothing
function agentended!(stream, ::WireRunning)
    stream.runended = Announced()
    stream.activity = WireIdle()
    nothing
end
finishrun!(stream, ::Unannounced) = nothing
function finishrun!(stream, ::Announced)
    write!(stream.io, (; type="agent_end", messages=stream.messages, willRetry=false))
    stream.runended = Unannounced()
end
function observe!(stream, ::TurnStart, event)
    retrybegin!(stream, stream.activity)
    stream.used = nothing
    stream.completion = nothing
    empty!(stream.results)
    empty!(stream.blocks)
    empty!(stream.calls)
    stream.active = nothing
    stream.started = Unannounced()
    stream.ended = Unannounced()
    stream.turnended = Unannounced()
    write!(stream.io, (; type="turn_start"))
    initial!(stream)
end
retrybegin!(stream, activity::WireActivity) = nothing
retrybegin!(stream, ::WireRetry) = observe!(stream, AgentStart(), nothing)
function observe!(stream, ::TurnEnd, event)
    write!(stream.io, (; type="turn_end", message=stream.assistant, toolResults=stream.results))
    stream.turnended = Announced()
end

abstract type Role end
struct UserRole <: Role end
struct SystemRole <: Role end
struct AssistantRole <: Role end
struct ToolRole <: Role end
struct OtherRole <: Role end
const roles = Dict("user" => UserRole(), "system" => SystemRole(), "assistant" => AssistantRole(), "tool" => ToolRole())
role(message) = get(roles, get(message, "role", ""), OtherRole())

function initialmessages(agent)
    values = Dict{String, Any}[]
    length(getfield(agent.state, :messages)) <= length(getfield(agent.initial, :messages)) || return values
    for raw in agent.messages
        initialmessage!(values, role(raw), raw)
    end
    values
end
initialmessage!(values, role::Role, raw) = nothing
initialmessage!(values, ::SystemRole, raw) = push!(values, Dict{String, Any}(raw))
function initial!(stream)
    for raw in stream.initial
        value = merge(raw, Dict("timestamp" => nowms()))
        write!(stream.io, (; type="message_start", message=value))
        write!(stream.io, (; type="message_end", message=value))
        push!(stream.messages, value)
    end
    empty!(stream.initial)
    nothing
end

function observe!(stream, ::MessageStart, event)
    stream.stamp = nowms()
    kind = role(event.message)
    started!(stream, kind)
    stream.current = message(stream, event.message, kind)
    write!(stream.io, (; type="message_start", message=stream.current))
end
started!(stream, role::Role) = nothing
started!(stream, ::AssistantRole) = (stream.started = Announced(); nothing)

function observe!(stream, ::MessageEnd, event)
    messageend!(stream, event.message, role(event.message))
end
function messageend!(stream, raw, role::Role)
    value = message(stream, raw, role)
    push!(stream.messages, value)
    write!(stream.io, (; type="message_end", message=value))
end
function messageend!(stream, raw, ::AssistantRole)
    closeblocks!(stream, raw)
    value = message(stream, raw, AssistantRole())
    stream.assistant = value
    stream.ended = Announced()
    push!(stream.messages, value)
    write!(stream.io, (; type="message_end", message=value))
end
function messageend!(stream, raw, ::ToolRole)
    value = message(stream, raw, ToolRole())
    push!(stream.messages, value)
    push!(stream.results, value)
    write!(stream.io, (; type="message_end", message=value))
end

image(value) = Dict("type" => "image", "data" => value["data"], "mimeType" => value["mime"])
image(value::Image) = Dict("type" => "image", "data" => value.data, "mimeType" => value.mime)
textblock(text) = Dict("type" => "text", "text" => text)
content(text, ::Nothing) = [textblock(text)]
content(text, images::AbstractVector) = [textblock(text); image.(images)]
function message(stream, raw, ::UserRole)
    Dict{String, Any}("role" => "user", "content" => content(get(raw, "content", ""), get(raw, "images", nothing)), "timestamp" => stream.stamp)
end

reason(::Nothing, raw) = isempty(get(raw, "tool_calls", [])) ? "pending" : "toolUse"
reason(result::Completion, raw) = reason(result, getfield(result, :status), raw)
reason(result, ::Unfinished, raw) = get(Dict("cancelled" => "aborted"), result.finish, "error")
reason(result, ::Finished, raw) = get(Dict("tool_calls" => "toolUse", "function_call" => "toolUse", "length" => "length"), result.finish, "stop")

function message(stream, raw, ::AssistantRole)
    value = Dict{String, Any}("role" => "assistant", "content" => assistantcontent(stream, raw), "api" => stream.api, "provider" => stream.provider, "model" => stream.model, "usage" => usage(stream.used), "stopReason" => reason(stream.completion, raw), "timestamp" => stream.stamp)
    failure!(value, stream.terminal, stream.completion)
    value
end
failure!(value, terminal, ::Nothing) = nothing
failure!(value, terminal, result::Completion) = failure!(value, terminal, result, getfield(result, :status))
failure!(value, terminal, result, ::Finished) = nothing
function failure!(value, terminal, result, ::Unfinished)
    value["errorMessage"] = redact(terminal, something(result.error, "Provider response incomplete"))
end

function message(stream, raw, ::ToolRole)
    id = get(raw, "tool_call_id", "")
    blocks = [textblock(get(raw, "content", ""))]
    image!(blocks, get(raw, "image", nothing))
    Dict{String, Any}("role" => "toolResult", "toolCallId" => id, "toolName" => get(stream.names, id, ""), "content" => blocks, "isError" => get(raw, "is_error", false), "timestamp" => stream.stamp)
end
message(stream, raw, ::Union{OtherRole, SystemRole}) = Dict{String, Any}(raw)
image!(blocks, ::Nothing) = blocks
image!(blocks, value) = (push!(blocks, image(value)); blocks)

assistantcontent(stream, raw) = assistantcontent(stream.blocks, raw)
function assistantcontent(blocks::Vector{<:Block}, raw)
    isempty(blocks) && return fallbackcontent(raw)
    [blockcontent(block) for block in blocks]
end
blockcontent(block::TextBlock) = textblock(buffertext(block.text))
blockcontent(block::ThinkingBlock) = Dict("type" => "thinking", "thinking" => buffertext(block.text))
blockcontent(block::CallBlock) = toolcall(block)
function fallbackcontent(raw)
    blocks = Dict{String, Any}[]
    addtext!(blocks, get(raw, "content", nothing))
    addthinking!(blocks, get(raw, "reasoning_content", get(raw, "reasoning", get(raw, "reasoning_text", nothing))))
    for call in get(raw, "tool_calls", [])
        push!(blocks, toolcall(call))
    end
    blocks
end
addtext!(blocks, ::Nothing) = blocks
addtext!(blocks, value::AbstractString) = isempty(value) ? blocks : (push!(blocks, textblock(value)); blocks)
addthinking!(blocks, ::Nothing) = blocks
addthinking!(blocks, value::AbstractString) = isempty(value) ? blocks : (push!(blocks, Dict("type" => "thinking", "thinking" => value)); blocks)

abstract type Arguments end
struct ParsedArguments <: Arguments
    value::Dict{String, Any}
end
struct InvalidArguments <: Arguments
    text::String
end
parsed(::Nothing) = ParsedArguments(Dict{String, Any}())
function parsed(text::AbstractString)
    depth = length(current_exceptions())
    try
        ParsedArguments(JSON3.read(codeunits(text), Dict{String, Any}))
    finally
        for failure in parsefailures(current_exceptions(), depth, text)
            return failure
        end
    end
end
parsefailures(exceptions, depth, text) = length(exceptions) > depth ? parsefailures(last(exceptions).exception, text) : ()
parsefailures(::ArgumentError, text) = (InvalidArguments(String(text)),)
parsefailures(exception, text) = ()
parsed(value::AbstractDict) = ParsedArguments(Dict{String, Any}(value))
parsed(value) = InvalidArguments(string(value))
arguments(value) = arguments(parsed(value))
arguments(value::ParsedArguments) = value.value
arguments(::InvalidArguments) = Dict{String, Any}()
toolcall(id, name, value) = toolcall(id, name, parsed(value))
toolcall(id, name, value::ParsedArguments) = Dict{String, Any}("type" => "toolCall", "id" => id, "name" => name, "arguments" => value.value)
toolcall(id, name, value::InvalidArguments) = Dict{String, Any}("type" => "toolCall", "id" => id, "name" => name, "arguments" => Dict{String, Any}(), "argumentsError" => "Invalid JSON arguments: " * value.text)
toolcall(block::CallBlock) = toolcall(block.id, block.name, buffertext(block.arguments))
function toolcall(raw::AbstractDict)
    fn = get(raw, "function", Dict())
    toolcall(get(raw, "id", ""), get(fn, "name", ""), get(fn, "arguments", nothing))
end

function update!(stream, event)
    write!(stream.io, (; type="message_update", usage=usage(stream.used), assistantMessageEvent=event))
end
function closeactive!(stream)
    closeactive!(stream, stream.active)
    stream.active = nothing
end
closeactive!(stream, ::Nothing) = nothing
closeactive!(stream, block::TextBlock) = update!(stream, (; type="text_end", contentIndex=block.index, content=buffertext(block.text)))
closeactive!(stream, block::ThinkingBlock) = update!(stream, (; type="thinking_end", contentIndex=block.index, content=buffertext(block.text)))

function beginblock!(stream, ::Type{T}) where T <: Union{TextBlock, ThinkingBlock}
    closeactive!(stream)
    block = T(length(stream.blocks), "")
    push!(stream.blocks, block)
    stream.active = block
    blockstart!(stream, block)
    block
end
blockstart!(stream, block::TextBlock) = update!(stream, (; type="text_start", contentIndex=block.index))
blockstart!(stream, block::ThinkingBlock) = update!(stream, (; type="thinking_start", contentIndex=block.index))
active!(stream, ::Type{T}, block::T) where T <: Union{TextBlock, ThinkingBlock} = block
active!(stream, ::Type{T}, block) where T <: Union{TextBlock, ThinkingBlock} = beginblock!(stream, T)

struct TextUpdate end
struct ThinkingUpdate end
struct CallUpdate end
const updates = Dict(:text => TextUpdate(), :thinking => ThinkingUpdate(), :tool_call => CallUpdate())
function observe!(stream, ::MessageUpdate, event)
    update!(stream, get(updates, event.assistant_event.type, nothing), event.assistant_event)
end
update!(stream, ::Nothing, event) = nothing
function update!(stream, ::TextUpdate, event)
    block = active!(stream, TextBlock, stream.active)
    write(block.text, event.text)
    update!(stream, (; type="text_delta", contentIndex=block.index, delta=event.text))
end
function update!(stream, ::ThinkingUpdate, event)
    block = active!(stream, ThinkingBlock, stream.active)
    write(block.text, event.text)
    update!(stream, (; type="thinking_delta", contentIndex=block.index, delta=event.text))
end
function update!(stream, ::CallUpdate, event)
    closeactive!(stream)
    block = get!(stream.calls, event.index) do
        block = CallBlock(length(stream.blocks), "", "", "", "", Unstarted())
        push!(stream.blocks, block)
        block
    end
    block.id = something(event.id, block.id)
    block.name = something(event.name, block.name)
    write(block.arguments, event.arguments)
    write(block.pending, event.arguments)
    startcall!(stream, block)
    isempty(event.arguments) && emptydelta!(stream, block, block.state)
end
emptydelta!(stream, block, ::Unstarted) = nothing
emptydelta!(stream, block, ::Started) = update!(stream, (; type="toolcall_delta", contentIndex=block.index, delta=""))
function startcall!(stream, block)
    isempty(block.id) || isempty(block.name) || startcall!(stream, block, block.state)
end
function startcall!(stream, block, ::Unstarted)
    update!(stream, (; type="toolcall_start", contentIndex=block.index, id=block.id, toolName=block.name))
    block.state = Started()
    stream.names[block.id] = block.name
    startcall!(stream, block, block.state)
end
function startcall!(stream, block, ::Started)
    pending = String(take!(block.pending))
    isempty(pending) || update!(stream, (; type="toolcall_delta", contentIndex=block.index, delta=pending))
end
textblocks!(items, ::Block) = items
textblocks!(items, block::TextBlock) = (push!(items, block); items)
callblocks!(items, ::Block) = items
callblocks!(items, block::CallBlock) = (push!(items, block); items)
reconciletext!(blocks, ::Nothing) = nothing
function reconciletext!(blocks, text::AbstractString)
    items = TextBlock[]
    foreach(block -> textblocks!(items, block), blocks)
    length(items) == 1 && settext!(only(items).text, text)
    nothing
end
rawarguments(value::AbstractString) = String(value)
rawarguments(value) = JSON3.write(value)
function reconcilecalls!(blocks, raw)
    items = CallBlock[]
    foreach(block -> callblocks!(items, block), blocks)
    for (block, call) in zip(items, raw)
        fn = get(call, "function", Dict())
        block.id = get(call, "id", block.id)
        block.name = get(fn, "name", block.name)
        settext!(block.arguments, rawarguments(get(fn, "arguments", buffertext(block.arguments))))
    end
end
function closeblocks!(stream, raw)
    reconciletext!(stream.blocks, get(raw, "content", nothing))
    reconcilecalls!(stream.blocks, get(raw, "tool_calls", []))
    closeactive!(stream)
    for block in stream.blocks
        closeblock!(stream, block)
    end
end
closeblock!(stream, block::Block) = nothing
function closeblock!(stream, block::CallBlock)
    startcall!(stream, block)
    update!(stream, (; type="toolcall_end", contentIndex=block.index, toolCall=toolcall(block)))
end

function observe!(stream, ::ToolStart, event)
    stream.names[event.tool_call_id] = something(event.tool_name, "")
    write!(stream.io, (; type="tool_execution_start", toolCallId=event.tool_call_id, toolName=event.tool_name, args=arguments(event.args)))
end
resultcontent(value) = resultcontent(value.text, value.image)
resultcontent(text, imagevalue) = image!([textblock(text)], imagevalue)
resultcontent(value::ShellUpdate) = [textblock(value.text)]
function observe!(stream, ::ToolUpdate, event)
    result = (; content=resultcontent(event.partial_result), details=Dict{String, Any}())
    write!(stream.io, (; type="tool_execution_update", toolCallId=event.tool_call_id, toolName=event.tool_name, args=arguments(event.args), partialResult=result))
end
function observe!(stream, ::ToolEnd, event)
    result = (; content=resultcontent(event.result), details=Dict{String, Any}())
    write!(stream.io, (; type="tool_execution_end", toolCallId=event.tool_call_id, toolName=event.tool_name, result, isError=event.iserror))
end

listener(snapshot::Nothing, callback) = callback
listener(snapshot::Extensions.Snapshot, callback) = Extensions.listen(snapshot; on_event=callback)

include("live_compaction.jl")

function runmode!(terminal::Terminal, agent::Agent, prompt, snapshot, on_agent_event, mode::JSONMode)
    policy = attempt(() -> J.terminalcompaction(agent.provider, mode.provider, ENV, pwd()))
    runjson!(terminal, agent, prompt, snapshot, on_agent_event, mode, policy)
end
function runjson!(terminal, agent, prompt, snapshot, on_agent_event, mode, failure::Union{J.Models.InvalidConfig, ToolFailure})
    println(terminal.diagnostics, "Invalid or unreadable compaction settings.")
    flush(terminal.diagnostics)
    2
end
function runjson!(terminal, agent, prompt, snapshot, on_agent_event, mode, policy::Union{Nothing, J.AutoCompaction})
    stream = Stream(terminal, agent, mode)
    recorder = Recorder(agent)
    backfill!(recorder, stream, recordpresence(recorder.entries))
    callback = listener(snapshot, event -> (observejson!(stream, recorder, event); on_agent_event(event)))
    result = try
        request!(terminal) do
            respond!(agent, prompt; on_event=ProviderObserver(stream), on_agent_event=callback, auto_compaction=policy)
        end
    finally
        failures!(terminal, callback)
    end
    finish!(stream, result, requeststatus(result.status))
end
abstract type RequestStatus end
struct RequestCompleted <: RequestStatus end
struct RequestFailed <: RequestStatus
    status::Int
end
const requeststatuses = Dict(0 => RequestCompleted())
requeststatus(status) = get(requeststatuses, status, RequestFailed(status))
function finish!(stream, result, ::RequestCompleted)
    finishrun!(stream, stream.runended)
    settled!(stream, result.value)
end
function finish!(stream, result, failed::RequestFailed)
    failedturn!(stream, get(failedfinishes, failed.status, nothing))
    finishrun!(stream, stream.runended)
    settled!(stream, get(failedsettlements, failed.status, nothing))
end
const failedfinishes = Dict(130 => "cancelled")
const failedsettlements = Dict(130 => :cancelled)
function failedturn!(stream, finish)
    raw = Dict{String, Any}("role" => "assistant", "content" => nothing)
    stream.completion = Completion(raw, nothing, finish, Unfinished(), "Provider request failed")
    failedstart!(stream, stream.started, raw)
    failedend!(stream, stream.ended, raw)
    failedturnend!(stream, stream.turnended)
end
failedstart!(stream, ::Announced, raw) = nothing
failedstart!(stream, ::Unannounced, raw) = observe!(stream, MessageStart(), (; message=raw))
failedend!(stream, ::Announced, raw) = nothing
failedend!(stream, ::Unannounced, raw) = messageend!(stream, raw, AssistantRole())
failedturnend!(stream, ::Announced) = nothing
failedturnend!(stream, ::Unannounced) = observe!(stream, TurnEnd(), nothing)
settled!(stream, value) = (write!(stream.io, (; type="agent_settled", aborted=false)); 0)
settled!(stream, value::Symbol) = (write!(stream.io, (; type="agent_settled", aborted=get(Dict(:cancelled => true), value, false))); 0)
settled!(stream, rejected::History.Rejected) = result!(stream.terminal, rejected)

function starttemplates!(terminal, agent, extensions, store, args, sessiondir, templates::Union{AbstractDict, Skills.Resources}, ::JSONMode)
    parsed = FileArguments.parse(args)
    files = attempt(() -> FileArguments.load(parsed.files, pwd()))
    startjson!(terminal, agent, extensions, store, templates, parsed.messages, files)
end
function startjson!(terminal, agent, extensions, store, templates, messages, failure::ToolFailure)
    println(terminal.diagnostics, "Could not read file argument: ", redact(terminal, failure.text))
    flush(terminal.diagnostics)
    1
end
function startjson!(terminal, agent, extensions, store, templates, messages, files::NamedTuple)
    initial = fileinput(stdin) * files.text * get(messages, 1, "")
    header!(terminal, store[])
    status = isempty(initial) ? 0 : run!(terminal, agent, fileprompt(Prompts.expand(initial, templates), files.images), extensions)
    for text in Iterators.drop(messages, 1)
        status = max(status, run!(terminal, agent, Prompts.expand(text, templates), extensions))
    end
    status
end

end
