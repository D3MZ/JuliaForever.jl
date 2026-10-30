struct Recorder{A}
    agent::A
    entries::Vector{J.Conversation.SessionRecordValue}
    leaf::Base.RefValue{Union{Nothing, String}}
end

function Recorder(agent)
    entries = J.Conversation.SessionRecordValue[]
    foreach(event -> collectrecord!(entries, event), getfield(agent, :events))
    leaf = isempty(entries) ? nothing : last(entries).id
    Recorder(agent, entries, Ref{Union{Nothing, String}}(leaf))
end

function textcallbacks(terminal, agent, snapshot, callback)
    stream = Stream(terminal, agent, JSONMode(terminal.mode.provider), devnull)
    recorder = Recorder(agent)
    backfill!(recorder, stream, recordpresence(recorder.entries))
    events = event -> (observejson!(stream, recorder, event); callback(event))
    TextProviderObserver(stream), J.observer(terminal, snapshot, events)
end
collectrecord!(entries, event) = nothing
collectrecord!(entries, event::J.Conversation.SessionRecord) = (push!(entries, event); nothing)
collectrecord!(entries, event::J.Conversation.ModelSelection) = (push!(entries, event.model, event.thinking); nothing)

abstract type RecordPresence end
struct NoRecordedMessages <: RecordPresence end
struct RecordedMessages <: RecordPresence end
recordpresence(entries) = foldl(recordpresence, entries; init=NoRecordedMessages())
recordpresence(state, record::J.Conversation.SessionRecord) = recordpresence(state, record.entry)
recordpresence(state, entry::J.Conversation.SessionEntry) = state
recordpresence(state, entry::J.Conversation.MessageEntry) = RecordedMessages()

function recordentry!(recorder::Recorder, entry::J.Conversation.SessionEntry)
    agent = recorder.agent
    lock(agent.lock) do
        id = bytes2hex(rand(UInt8, 8))
        timestamp = isotime()
        result, _ = J.transition!(revision -> J.Conversation.SessionRecord(revision, id, recorder.leaf[], timestamp, entry), agent)
        recorded!(recorder, result)
    end
end
recorded!(recorder, rejected::History.Rejected) = rejected
function recorded!(recorder, result::J.Kernel.Applied)
    record = last(getfield(recorder.agent, :events))
    push!(recorder.entries, record)
    recorder.leaf[] = record.id
    nothing
end

recordmessage!(recorder, message) = recordentry!(recorder, J.Conversation.MessageEntry(JSON3.read(codeunits(JSON3.write(message)), Dict{String, Any})))
recordmessages!(recorder, messages) = foreach(message -> recordmessage!(recorder, message), messages)

function backfill!(recorder, stream, ::RecordedMessages)
    remembercalls!(stream, recorder.entries)
    foreach(message -> backfillmessage!(recorder, stream, message), unrecordedmessages(recorder.agent))
    nothing
end
function backfill!(recorder, stream, ::NoRecordedMessages)
    agent = recorder.agent
    messages = getfield(agent.state, :messages)
    length(messages) <= length(getfield(agent.initial, :messages)) && return nothing
    foreach(message -> backfillmessage!(recorder, stream, message), messages)
    nothing
end
backfillmessage!(recorder, stream, message) = backfillvalue!(recorder, wiremessage(stream, message))
backfillvalue!(recorder, ::Nothing) = nothing
backfillvalue!(recorder, message::AbstractDict) = recordmessage!(recorder, message)

remembercalls!(stream, entries::AbstractVector) = foreach(entry -> remembercalls!(stream, entry), entries)
remembercalls!(stream, record::J.Conversation.SessionRecord) = remembercalls!(stream, record.entry)
remembercalls!(stream, entry::J.Conversation.SessionEntry) = nothing
remembercalls!(stream, entry::J.Conversation.MessageEntry) = rememberblocks!(stream, get(entry.message, "content", nothing))
rememberblocks!(stream, content) = nothing
rememberblocks!(stream, blocks::AbstractVector) = foreach(block -> rememberblock!(stream, block), blocks)
rememberblock!(stream, block) = nothing
rememberblock!(stream, block::AbstractDict) = get(calltypes, get(block, "type", ""), ignorecall!)(stream, block)
ignorecall!(stream, block) = nothing
remembercall!(stream, block) = (stream.names[block["id"]] = block["name"]; nothing)
const calltypes = Dict("toolCall" => remembercall!)

function unrecordedmessages(agent)
    initial, events, phase = lock(agent.lock) do
        (agent.initial, copy(getfield(agent, :events)), agent.state.phase)
    end
    index = foldl(recordindex, enumerate(events); init=0)
    unrecordedmessages(initial, events, index, phase)
end
recordindex(previous, item::Tuple) = recordindex(previous, item...)
recordindex(previous, index, event) = previous
recordindex(previous, index, ::J.Conversation.SessionRecord{J.Conversation.MessageEntry}) = index
unrecordedmessages(initial, events, index, phase::J.Conversation.Phase) = replayunrecorded(initial, events, index)
function unrecordedmessages(initial, events, index, ::J.Conversation.CompletePhase)
    change = foldl(unrecordedchange, @view(events[index+1:end]); init=nothing)
    unrecordedmessages(initial, events, index, change)
end
unrecordedchange(change, event) = change
unrecordedchange(change, event::Union{J.Conversation.Input, J.Conversation.ImageInput, J.Conversation.BashOutput, J.Conversation.Abandon, J.Kernel.Observe{J.Conversation.ModelReply}, J.Kernel.Observe{J.Conversation.ToolReply}}) = event
unrecordedmessages(initial, events, index, ::Nothing) = J.Conversation.Message[]
unrecordedmessages(initial, events, index, event::J.Kernel.Event) = replayunrecorded(initial, events, index)
function replayunrecorded(initial, events, index::Int)
    state = initial
    for event in @view events[1:index]
        state = J.Kernel.step(state, event).state
    end
    messages = J.Conversation.Message[]
    for event in @view events[index+1:end]
        next = J.Kernel.step(state, event).state
        unrecorded!(messages, state, next, event)
        state = next
    end
    messages
end
unrecorded!(messages, before, after, ::Union{J.Conversation.History, J.Conversation.SystemUpdate}) = nothing
function unrecorded!(messages, before, after, event)
    prior = length(getfield(before, :messages))
    values = getfield(after, :messages)
    append!(messages, @view values[prior+1:end])
    nothing
end

wiremessage(stream, value::J.Conversation.Message) = nothing
wiremessage(stream, value::Union{J.Conversation.User, J.Conversation.ImageUser, J.Conversation.ToolMessage, J.Conversation.SkillContext}) = wiremessage(stream, convert(Dict{String, Any}, value))
wiremessage(stream, value::J.Conversation.RawMessage) = wiremessage(stream, value.value)
wiremessage(stream, value::J.Conversation.BashMessage) = convert(Dict{String, Any}, value)
wiremessage(stream, raw::AbstractDict) = wiremessage(stream, raw, role(raw))
wiremessage(stream, raw, kind::Role) = nothing
wiremessage(stream, raw, kind::Union{UserRole, SystemRole, ToolRole}) = message(stream, raw, kind)
wiremessage(stream, raw, ::AssistantRole) = wiremessage(stream, J.conversation_reply((; message=raw, result=nothing)).message)
function wiremessage(stream, value::J.Conversation.Assistant)
    raw = convert(Dict{String, Any}, value)
    for call in value.calls
        stream.names[call.id] = something(call.name, "")
    end
    result = J.Completion(raw, nothing, value.finish, getfield(value, :status), nothing)
    data = Dict{String, Any}("role" => "assistant", "content" => fallbackcontent(raw), "stopReason" => reason(result, raw))
    wireinfo!(data, value.info)
end
wireinfo!(data, ::Nothing) = data
function wireinfo!(data, info::J.Conversation.ResponseInfo)
    field!(data, "api", info.api)
    field!(data, "provider", info.provider)
    field!(data, "model", info.model)
    field!(data, "timestamp", info.timestamp)
    wireusage!(data, info.usage)
end
wireusage!(data, ::Nothing) = data
wireusage!(data, used::J.Usage) = (data["usage"] = usage(used); data)

nativekey(message::J.Conversation.Message) = nothing
nativekey(message::J.Conversation.User) = (:user, message.content, ())
nativekey(message::J.Conversation.ImageUser) = (:user, message.content, Tuple((image.mime, image.data) for image in message.images))
nativekey(message::J.Conversation.Assistant) = (:assistant, something(message.content, ""), Tuple(call.id for call in message.calls))
nativekey(message::J.Conversation.ToolMessage) = (:tool, message.id)
nativekey(message::J.Conversation.BashMessage) = (:bash, message.command, message.timestamp)
nativekey(message::J.Conversation.RawMessage) = rawkey(message.value, role(message.value))
rawkey(message, role::Role) = nothing
rawkey(message, ::UserRole) = (:user, get(message, "content", ""), Tuple((image["mime"], image["data"]) for image in get(message, "images", [])))
rawkey(message, ::AssistantRole) = (:assistant, something(get(message, "content", nothing), ""), Tuple(call["id"] for call in get(message, "tool_calls", [])))
rawkey(message, ::ToolRole) = (:tool, get(message, "tool_call_id", ""))

blocktext(block) = get(blocktexts, get(block, "type", ""), othertext)(block)
othertext(block) = ""
textvalue(block) = get(block, "text", "")
const blocktexts = Dict("text" => textvalue)
blockimage(block) = get(blockimages, get(block, "type", ""), otherimage)(block)
otherimage(block) = ()
imagevalue(block) = ((get(block, "mimeType", ""), get(block, "data", "")),)
const blockimages = Dict("image" => imagevalue)
blockcall(block) = get(blockcalls, get(block, "type", ""), othercall)(block)
othercall(block) = ()
callvalue(block) = (get(block, "id", ""),)
const blockcalls = Dict("toolCall" => callvalue)
blockcontent(content::AbstractString) = (String(content), ())
blockcontent(content::AbstractVector) = (join(blocktext.(content)), Tuple(Iterators.flatten(blockimage.(content))))
blockcontent(content) = ("", ())
blockids(content::AbstractVector) = Tuple(Iterators.flatten(blockcall.(content)))
blockids(content) = ()

wirekey(record) = wirekey(record.entry)
wirekey(entry::J.Conversation.SessionEntry) = nothing
wirekey(entry::J.Conversation.MessageEntry) = get(wirekeys, get(entry.message, "role", ""), otherkey)(entry.message)
otherkey(message) = nothing
userkey(message) = (:user, blockcontent(get(message, "content", ""))...)
assistantkey(message) = (:assistant, first(blockcontent(get(message, "content", ""))), blockids(get(message, "content", [])))
toolkey(message) = (:tool, get(message, "toolCallId", ""))
bashkey(message) = (:bash, get(message, "command", ""), get(message, "timestamp", nothing))
const wirekeys = Dict("user" => userkey, "assistant" => assistantkey, "toolResult" => toolkey, "bashExecution" => bashkey)

function firstkept(entries, retained)
    found = foldl((state, message) -> keptstep(entries, state, message), Iterators.reverse(retained); init=(length(entries), nothing))
    keptid(found)
end
keptstep(entries, ::Nothing, message) = nothing
keptstep(entries, state::Tuple, message) = keptfound(entries, findkept(entries, nativekey(message), first(state)))
findkept(entries, ::Nothing, index) = nothing
findkept(entries, wanted, index) = findprev(entry -> wirekey(entry) == wanted, entries, index)
keptfound(entries, ::Nothing) = nothing
keptfound(entries, index::Int) = (index - 1, entries[index].id)
keptid(::Nothing) = nothing
keptid(state::Tuple) = last(state)

compactionentry(event, entries) = compactionentry(event.result, event, entries)
compactionentry(result, event, entries) = nothing
function compactionentry(result::AbstractString, event, entries)
    J.Conversation.CompactionEntry(String(result), firstkept(entries, event.plan.retained), event.tokens_before, event.estimated_after, event.info)
end

function compactionstart!(stream, event)
    finishrun!(stream, stream.runended)
    get(compactionstarts, event.reason, identity)(stream)
    write!(stream.io, (; type="compaction_start", reason=String(event.reason)))
end
overflowend!(stream) = overflowend!(stream, stream.activity)
overflowend!(stream, activity::WireActivity) = nothing
function overflowend!(stream, ::WireRunning)
    write!(stream.io, (; type="agent_end", messages=stream.messages, willRetry=false))
    stream.activity = WireIdle()
    nothing
end
const compactionstarts = Dict(:overflow => overflowend!)

compactiondata(entry::J.Conversation.CompactionEntry) = compactiondata(entry, entry.info)
function compactiondata(entry, info)
    data = Dict{String, Any}("summary" => entry.summary, "tokensBefore" => entry.tokens_before, "estimatedTokensAfter" => entry.estimated_after)
    field!(data, "firstKeptEntryId", entry.firstkept)
    compactionusage!(data, info)
end
compactionusage!(data, ::Nothing) = data
compactionusage!(data, info::J.Conversation.ResponseInfo) = compactionusage!(data, info.usage)
compactionusage!(data, value::J.Usage) = (data["usage"] = usage(value); data)
field!(data, key, ::Nothing) = data
field!(data, key, value) = (data[key] = value; data)

function compactionend!(stream, event, entry)
    get(compactionends, event.reason, identity)(stream)
    write!(stream.io, compactionevent(stream.terminal, event, entry))
    retrywire!(stream, get(retrystates, (event.reason, event.will_retry), WireIdle()))
end
const compactionends = Dict(:overflow => overflowend!)
const retrystates = Dict((:overflow, true) => WireRetry())
retrywire!(stream, ::WireIdle) = nothing
retrywire!(stream, retry::WireRetry) = (stream.activity = retry; nothing)
compactionevent(terminal, event, entry::J.Conversation.CompactionEntry) = (; type="compaction_end", reason=String(event.reason), result=compactiondata(entry), aborted=false, willRetry=event.will_retry)
compactionevent(terminal, event, ::Nothing) = compactionfailure(terminal, event, event.result)
compactionfailure(terminal, event, ::Symbol) = (; type="compaction_end", reason=String(event.reason), aborted=true, willRetry=false)
function compactionfailure(terminal, event, rejected::History.Rejected)
    prefix = get(Dict(:overflow => "Context overflow recovery failed: "), event.reason, "Auto-compaction failed: ")
    (; type="compaction_end", reason=String(event.reason), aborted=false, willRetry=false, errorMessage=prefix * String(rejected.reason))
end
compactionfailure(terminal, event, result) = (; type="compaction_end", reason=String(event.reason), aborted=false, willRetry=false, errorMessage="Auto-compaction failed.")

observejson!(stream, recorder, event) = observejson!(stream, recorder, get(events, event.type, nothing), event)
observejson!(stream, recorder, kind, event) = observe!(stream, kind, event)
function observejson!(stream, recorder, kind::Union{TurnStart, MessageEnd}, event)
    before = length(stream.messages)
    observe!(stream, kind, event)
    recordmessages!(recorder, @view stream.messages[before+1:end])
end
observejson!(stream, recorder, ::CompactionStart, event) = compactionstart!(stream, event)
function observejson!(stream, recorder, ::CompactionEnd, event)
    entry = compactionentry(event, recorder.entries)
    savecompaction!(recorder, entry)
    compactionend!(stream, event, entry)
end
savecompaction!(recorder, ::Nothing) = nothing
savecompaction!(recorder, entry::J.Conversation.CompactionEntry) = recordentry!(recorder, entry)
