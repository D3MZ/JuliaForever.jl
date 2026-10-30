abstract type Role end
struct User <: Role end
struct System <: Role end
struct Assistant <: Role end
struct Tool <: Role end

abstract type Event end
struct AgentStart <: Event end
struct TurnStart <: Event end
struct MessageStart <: Event end
struct MessageUpdate <: Event end
struct MessageEnd <: Event end
struct TurnEnd <: Event end
struct AgentEnd <: Event end
struct ToolStart <: Event end
struct ToolUpdate <: Event end
struct ToolEnd <: Event end

abstract type BlockState end
struct NewBlock <: BlockState end
struct ExistingBlock <: BlockState end

abstract type ProviderEvent end
struct UsageReported <: ProviderEvent end
struct CompletionReported <: ProviderEvent end

apiname(::J.OpenAI) = "openai-completions"
apiname(::J.OpenAIResponses) = "openai-responses"
apiname(::J.Anthropic) = "anthropic-messages"
apiname(::J.Google) = "google-generative-ai"

cost(::Nothing) = (; input=0.0, output=0.0, cacheRead=0.0, cacheWrite=0.0, total=0.0)
cost(usage::J.Usage) = cost(usage.cost)
cost(value::Float64) = (; input=0.0, output=0.0, cacheRead=0.0, cacheWrite=0.0, total=value)

usage(::Nothing) = (; input=0, output=0, cacheRead=0, cacheWrite=0, totalTokens=0, cost=cost(nothing))
usage(value::J.Usage) = (; input=value.input, output=value.output, cacheRead=value.cache_read, cacheWrite=value.cache_write, totalTokens=value.total, cost=cost(value))

arguments(value::AbstractString) = arguments(J.decode(value))
arguments(::J.InvalidResponse) = Dict{String, Any}()
arguments(value) = value

buffertext(buffer::IOBuffer) = String(take!(copy(buffer)))
function settext!(buffer::IOBuffer, text)
    truncate(buffer, 0)
    seekstart(buffer)
    write(buffer, text)
    nothing
end

wire(block::TextBlock) = (; type="text", text=buffertext(block.text))
wire(block::ThinkingBlock) = (; type="thinking", thinking=buffertext(block.text))
wire(block::CallBlock) = (; type="toolCall", id=block.id, name=block.name, arguments=arguments(buffertext(block.arguments)))

stopreason(::Nothing) = "pending"
stopreason(result::J.Completion) = completionreason(getfield(result, :status), result.finish)
const failedreasons = Dict("cancelled" => "aborted")
completionreason(::J.Unfinished, finish) = get(failedreasons, finish, "error")
const stopreasons = Dict("length" => "length", "tool_calls" => "toolUse", "function_call" => "toolUse")
completionreason(::J.Finished, finish) = get(stopreasons, finish, "stop")
stopreason(result, ::J.Cancelled) = "aborted"
stopreason(result, ::Union{J.Idle, J.Running}) = stopreason(result)

function assistant(session)
    stream = session.stream
    turn = J.turnstate(session.agent)
    value = (; role="assistant", content=map(wire, stream.blocks), api=apiname(session.agent.provider), provider=session.terminal.provider, model=session.agent.provider.model, usage=usage(stream.usage), stopReason=stopreason(stream.completion, turn), timestamp=stream.timestamp)
    merge(value, errordetail(turn, stream.completion))
end
errordetail(::J.Cancelled, result) = (; errorMessage="Request cancelled")
errordetail(::Union{J.Idle, J.Running}, ::Nothing) = NamedTuple()
errordetail(::Union{J.Idle, J.Running}, result::J.Completion) = errordetail(result.error)
errordetail(::Nothing) = NamedTuple()
errordetail(failure::J.ProviderStatus) = (; errorMessage="Provider request failed (HTTP $(failure.status))")
errordetail(failure) = (; errorMessage="Provider request failed")

function message(session, ::User, raw)
    blocks = Any[(; type="text", text=get(raw, "content", ""))]
    append!(blocks, [wireimage(image) for image in get(raw, "images", [])])
    (; role="user", content=blocks, timestamp=round(Int, time() * 1000))
end

wireimage(image) = (; type="image", data=image["data"], mimeType=image["mime"])
wireimage(image::J.Image) = (; type="image", data=image.data, mimeType=image.mime)
message(session, ::System, raw) = (; role="system", content=get(raw, "content", ""), timestamp=round(Int, time() * 1000))
function message(session, ::Tool, raw)
    id = get(raw, "tool_call_id", "")
    content = Any[(; type="text", text=get(raw, "content", ""))]
    image!(content, get(raw, "image", nothing))
    (; role="toolResult", toolCallId=id, toolName=get(session.toolnames, id, ""), content, isError=get(raw, "is_error", false), timestamp=round(Int, time() * 1000))
end
image!(content, ::Nothing) = nothing
image!(content, image) = push!(content, wireimage(image))

const roles = Dict("user" => User(), "system" => System(), "assistant" => Assistant(), "tool" => Tool())

function restore!(session, agent)
    messages = getfield(agent.state, :messages)
    length(messages) <= length(getfield(agent.initial, :messages)) && return session
    session.statistics = UnavailableStatistics()
    for value in messages
        restore!(session, value)
    end
    session.firstturn = J.Announced()
    session
end
restore!(session, value::J.Conversation.Message) = nothing
restore!(session, value::Union{J.Conversation.User, J.Conversation.ImageUser, J.Conversation.ToolMessage, J.Conversation.Summary}) = restore!(session, convert(Dict{String, Any}, value))
restore!(session, value::J.Conversation.RawMessage) = restore!(session, value.value)
restore!(session, raw::AbstractDict) = restore!(session, get(roles, get(raw, "role", ""), nothing), raw)
restore!(session, ::Nothing, raw) = nothing
restore!(session, ::Assistant, raw) = restore!(session, J.conversation_reply((; message=raw, result=nothing)).message)
function restore!(session, role::Union{User, System, Tool}, raw)
    value = message(session, role, raw)
    push!(session.messages, Base.structdiff(value, NamedTuple{(:timestamp,)}))
end
function restore!(session, value::J.Conversation.Assistant)
    blocks = NamedTuple[]
    restoretext!(blocks, value.content)
    for call in value.calls
        name = something(call.name, "")
        session.toolnames[call.id] = name
        push!(blocks, (; type="toolCall", id=call.id, name, arguments=arguments(something(call.arguments, ""))))
    end
    restored = (; role="assistant", content=blocks, stopReason=completionreason(getfield(value, :status), value.finish))
    session.assistant = restored
    session.lastcontent = value.content
    push!(session.messages, restored)
end
restoretext!(blocks, ::Nothing) = nothing
restoretext!(blocks, text::String) = push!(blocks, (; type="text", text))

function initial!(session, ::J.Unannounced)
    session.firstturn = J.Announced()
    for raw in session.agent.messages
        initial!(session, get(roles, get(raw, "role", ""), nothing), raw)
    end
end
initial!(session, ::Nothing, raw) = nothing
initial!(session, ::Union{User, Assistant, Tool}, raw) = nothing
function initial!(session, ::System, raw)
    value = message(session, System(), raw)
    write!(session, (; type="message_start", message=value))
    write!(session, (; type="message_end", message=value))
    push!(session.messages, value)
end

initial!(session) = initial!(session, session.firstturn)
initial!(session, ::J.Announced) = nothing

const lifecycle = Dict(
    :agent_start => AgentStart(), :turn_start => TurnStart(), :message_start => MessageStart(), :message_update => MessageUpdate(),
    :message_end => MessageEnd(), :turn_end => TurnEnd(), :agent_end => AgentEnd(),
    :tool_execution_start => ToolStart(), :tool_execution_update => ToolUpdate(), :tool_execution_end => ToolEnd(),
)
event!(session, event) = lock(() -> event!(session, get(lifecycle, event.type, nothing), event), session.lock)
event!(session, ::Nothing, event) = nothing
function event!(session, ::AgentStart, event)
    notify(session.started)
    session.runstart = length(session.messages)
    session.runended = J.Unannounced()
    write!(session, (; type="agent_start"))
end
function event!(session, ::TurnStart, event)
    empty!(session.turntools)
    session.stream = Stream()
    session.turnended = J.Unannounced()
    write!(session, (; type="turn_start"))
    initial!(session)
end

event!(session, ::MessageStart, event) = start!(session, get(roles, event.message["role"], User()), event.message)
start!(session, ::Assistant, raw) = (session.stream.timestamp = round(Int, time() * 1000); nothing)
function start!(session, role, raw)
    queues!(session)
    session.current = message(session, role, raw)
    write!(session, (; type="message_start", message=session.current))
end

event!(session, ::MessageUpdate, event) = update!(session, J.agentupdate(event.assistant_event))
update!(session, ::Nothing) = nothing
update!(session, update::J.AgentText) = updatetext!(session, update.event)
update!(session, update::J.AgentThinking) = updatethinking!(session, update.event)
update!(session, update::J.AgentToolCall) = updatecall!(session, update.event)

block!(stream, key, constructor) = block!(stream, key, constructor, get(stream.indexes, key, nothing))
block!(stream, key, constructor, index::Int) = (index, ExistingBlock())
function block!(stream, key, constructor, ::Nothing)
    push!(stream.blocks, constructor())
    index = length(stream.blocks)
    stream.indexes[key] = index
    index, NewBlock()
end

announce!(session) = announce!(session, session.stream.announced)
announce!(session, ::J.Announced) = nothing
function announce!(session, ::J.Unannounced)
    session.stream.announced = J.Announced()
    write!(session, (; type="message_start", message=assistant(session)))
end

delta!(session, value) = write!(session, (; type="message_update", usage=usage(session.stream.usage), assistantMessageEvent=value))

function updatetext!(session, event)
    stream = session.stream
    index, state = block!(stream, (:text, ""), TextBlock)
    block = stream.blocks[index]::TextBlock
    write(block.text, event.text)
    announce!(session)
    startdelta!(session, state, (; type="text_start", contentIndex=index - 1))
    delta!(session, (; type="text_delta", contentIndex=index - 1, delta=event.text))
end

function updatethinking!(session, event)
    stream = session.stream
    index, state = block!(stream, (:thinking, ""), ThinkingBlock)
    block = stream.blocks[index]::ThinkingBlock
    write(block.text, event.text)
    announce!(session)
    startdelta!(session, state, (; type="thinking_start", contentIndex=index - 1))
    delta!(session, (; type="thinking_delta", contentIndex=index - 1, delta=event.text))
end

startdelta!(session, ::ExistingBlock, value) = nothing
startdelta!(session, ::NewBlock, value) = delta!(session, value)
fillvalue(old, ::Nothing) = old
fillvalue(old, new) = isempty(old) ? String(new) : old

function updatecall!(session, event)
    stream = session.stream
    key = (:tool, string(event.index))
    index, state = block!(stream, key, CallBlock)
    block = stream.blocks[index]::CallBlock
    block.id = fillvalue(block.id, event.id)
    block.name = fillvalue(block.name, event.name)
    write(block.arguments, event.arguments)
    stream.ids[block.id] = index
    announce!(session)
    startdelta!(session, state, (; type="toolcall_start", contentIndex=index - 1, id=block.id, toolName=block.name))
    delta!(session, (; type="toolcall_delta", contentIndex=index - 1, delta=event.arguments))
end

endblock!(session, index, block::TextBlock) = delta!(session, (; type="text_end", contentIndex=index - 1, content=buffertext(block.text)))
endblock!(session, index, block::ThinkingBlock) = delta!(session, (; type="thinking_end", contentIndex=index - 1, content=buffertext(block.text)))
endblock!(session, index, block::CallBlock) = delta!(session, (; type="toolcall_end", contentIndex=index - 1, toolCall=wire(block)))

event!(session, ::MessageEnd, event) = end!(session, get(roles, event.message["role"], User()), event.message)
function end!(session, ::Assistant, raw)
    finalcontent!(session.stream, get(raw, "content", nothing))
    finalcalls!(session.stream, get(raw, "tool_calls", []))
    announce!(session)
    for (index, block) in enumerate(session.stream.blocks)
        endblock!(session, index, block)
    end
    session.assistant = assistant(session)
    recordprice!(session, session.stream.usage)
    session.lastcontent = join(blocktext.(session.stream.blocks))
    push!(session.messages, session.assistant)
    write!(session, (; type="message_end", message=session.assistant))
    session.stream.ended = J.Announced()
end

finalcontent!(stream, ::Nothing) = nothing
function finalcontent!(stream, value::AbstractString)
    isempty(value) && return nothing
    index, _ = block!(stream, (:text, ""), TextBlock)
    block = stream.blocks[index]::TextBlock
    settext!(block.text, value)
end
function finalcalls!(stream, calls)
    for call in calls
        info = J.callinfo(call)
        id = String(call["id"])
        finalcall!(stream, id, info, get(stream.ids, id, nothing))
    end
end
function finalcall!(stream, id, info, ::Nothing)
    push!(stream.blocks, CallBlock(id, something(info.name, ""), something(info.args, "")))
end
function finalcall!(stream, id, info, index::Int)
    block = stream.blocks[index]::CallBlock
    block.id = id
    block.name = something(info.name, block.name)
    finalarguments!(block.arguments, info.args)
end
finalarguments!(buffer, ::Nothing) = nothing
finalarguments!(buffer, value::AbstractString) = settext!(buffer, value)
function end!(session, role, raw)
    push!(session.messages, session.current)
    endtool!(session, role, session.current)
    write!(session, (; type="message_end", message=session.current))
end
endtool!(session, role, value) = nothing
endtool!(session, ::Tool, value) = push!(session.turntools, value)
function event!(session, ::TurnEnd, event)
    endturn!(session, turnmessage(session, event.message))
end
function endturn!(session, message)
    write!(session, (; type="turn_end", message, toolResults=copy(session.turntools)))
    session.turnended = J.Announced()
end
turnmessage(session, ::Nothing) = nothing
turnmessage(session, message) = session.assistant
event!(session, ::AgentEnd, event) = (session.runended = J.Announced(); nothing)
finishrun!(session, ::J.Unannounced) = nothing
function finishrun!(session, ::J.Announced)
    write!(session, (; type="agent_end", messages=copy(session.messages[session.runstart+1:end]), willRetry=false))
    session.runended = J.Unannounced()
end

function failedturn!(session, finish)
    lock(session.lock) do
        announce!(session)
        session.stream.completion = J.Completion(Dict{String, Any}("role" => "assistant", "content" => nothing), nothing, finish, false, "Provider request failed")
        failedmessage!(session, session.stream.ended)
        failedend!(session, session.turnended)
    end
end
failedmessage!(session, ::J.Announced) = nothing
failedmessage!(session, ::J.Unannounced) = end!(session, Assistant(), Dict{String, Any}())
failedend!(session, ::J.Announced) = nothing
failedend!(session, ::J.Unannounced) = endturn!(session, session.assistant)

function toolresult(result::J.ToolResult)
    content = NamedTuple[(; type="text", text=result.text)]
    image!(content, result.image)
    (; content, details=Dict{String, Any}())
end
toolresult(result::J.ShellUpdate) = (; content=[(; type="text", text=result.text)], details=Dict{String, Any}())
function event!(session, ::ToolStart, event)
    session.toolnames[event.tool_call_id] = something(event.tool_name, "")
    write!(session, (; type="tool_execution_start", toolCallId=event.tool_call_id, toolName=event.tool_name, args=arguments(event.args)))
end
event!(session, ::ToolUpdate, event) = write!(session, (; type="tool_execution_update", toolCallId=event.tool_call_id, toolName=event.tool_name, args=arguments(event.args), partialResult=toolresult(event.partial_result)))
event!(session, ::ToolEnd, event) = write!(session, (; type="tool_execution_end", toolCallId=event.tool_call_id, toolName=event.tool_name, result=toolresult(event.result), isError=event.iserror))

const providers = Dict(:usage => UsageReported(), :done => CompletionReported(), :incomplete => CompletionReported())
provider!(session, event) = lock(() -> provider!(session, get(providers, event.type, nothing), event), session.lock)
provider!(session, ::Nothing, event) = nothing
provider!(session, ::UsageReported, event) = (session.stream.usage = event.usage; nothing)
provider!(session, ::CompletionReported, event) = (session.stream.completion = event.result; session.stream.usage = event.result.usage; nothing)
