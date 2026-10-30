function restore!(session, agent)
    messages = getfield(agent.state, :messages)
    length(messages) <= length(getfield(agent.initial, :messages)) && return session
    session.statistics = RestoredStatistics()
    for value in messages
        restore!(session, value)
    end
    session
end

restore!(session, value::J.Conversation.Message) = nothing
restore!(session, value::Union{J.Conversation.User, J.Conversation.ImageUser, J.Conversation.ToolMessage, J.Conversation.SkillContext}) = restore!(session, convert(Dict{String, Any}, value))
restore!(session, value::J.Conversation.Summary) = restoresummary!(session, value, findlast(record -> summaryvalue(record.entry) == value.content, session.entries))
summaryvalue(entry::J.Conversation.SessionEntry) = nothing
summaryvalue(entry::J.Conversation.CompactionEntry) = entry.summary
restoresummary!(session, value, ::Nothing) = restore!(session, convert(Dict{String, Any}, value))
function restoresummary!(session, value, index::Int)
    record = session.entries[index]
    timestamp = round(Int, 1000 * Dates.datetime2unix(Dates.DateTime(chop(record.timestamp; tail=1))))
    push!(session.messages, Dict{String, Any}("role" => "compactionSummary", "summary" => value.content, "tokensBefore" => record.entry.tokens_before, "timestamp" => timestamp))
    nothing
end
restore!(session, value::J.Conversation.RawMessage) = restore!(session, value.value)
restore!(session, value::J.Conversation.BashMessage) = push!(session.messages, convert(Dict{String, Any}, value))
restore!(session, raw::AbstractDict) = restore!(session, LiveJSON.role(raw), raw)
restore!(session, role::LiveJSON.Role, raw) = nothing
restore!(session, ::LiveJSON.AssistantRole, raw) = restore!(session, J.conversation_reply((; message=raw, result=nothing)).message)
function restore!(session, role::Union{LiveJSON.UserRole, LiveJSON.SystemRole, LiveJSON.ToolRole}, raw)
    value = LiveJSON.message(session.stream, raw, role)
    pop!(value, "timestamp", nothing)
    push!(session.messages, value)
end
function restore!(session, value::J.Conversation.Assistant)
    raw = convert(Dict{String, Any}, value)
    for call in value.calls
        session.stream.names[call.id] = something(call.name, "")
    end
    result = J.Completion(raw, nothing, value.finish, getfield(value, :status), nothing)
    message = Dict{String, Any}("role" => "assistant", "content" => LiveJSON.fallbackcontent(raw), "stopReason" => LiveJSON.reason(result, raw))
    restoreinfo!(session, message, value.info)
    session.lastcontent = value.content
    push!(session.messages, message)
end

restoreinfo!(session, message, ::Nothing) = (session.statistics = UnavailableStatistics(); nothing)
function restoreinfo!(session, message, info::J.Conversation.ResponseInfo)
    optional!(message, "api", info.api)
    optional!(message, "provider", info.provider)
    optional!(message, "model", info.model)
    optional!(message, "timestamp", info.timestamp)
    restoreusage!(session, message, info.usage)
end
restoreusage!(session, message, ::Nothing) = (session.statistics = UnavailableStatistics(); nothing)
function restoreusage!(session, message, usage::J.Usage)
    message["usage"] = LiveJSON.usage(usage)
    recordprice!(session, usage)
    nothing
end

struct ProviderObserver{S}
    session::S
end
function (observer::ProviderObserver)(event)
    session = observer.session
    lock(() -> LiveJSON.provider!(session.stream, event), session.lock)
end
function J.providercomplete!(observer::ProviderObserver, result::J.Completion)
    session = observer.session
    lock(() -> LiveJSON.complete!(session.stream, result), session.lock)
end

function event!(session, event)
    lock(session.lock) do
        event!(session, get(LiveJSON.events, event.type, nothing), event)
    end
end
event!(session, ::Nothing, event) = nothing
function event!(session, kind::LiveJSON.AgentStart, event)
    notify(session.started)
    LiveJSON.observe!(session.stream, kind, event)
end
function event!(session, kind::LiveJSON.CompactionStart, event)
    notify(session.started)
    session.compaction = Compacting()
    LiveJSON.compactionstart!(session.stream, event)
end
function event!(session, kind::LiveJSON.CompactionEnd, event)
    entry = LiveJSON.compactionentry(event, session.entries)
    compacted!(session, entry)
    session.compaction = CompactionIdle()
    LiveJSON.compactionend!(session.stream, event, entry)
end
compacted!(session, ::Nothing) = nothing
function compacted!(session, entry::J.Conversation.CompactionEntry)
    entrysaved!(session, recordentry!(session, entry))
    empty!(session.messages)
    session.lastcontent = nothing
    session.statistics = RestoredStatistics()
    foreach(message -> restore!(session, message), getfield(session.agent.state, :messages))
    nothing
end
function event!(session, kind::LiveJSON.MessageStart, event)
    queues!(session)
    observe!(session, kind, event)
end
function event!(session, kind::LiveJSON.TurnStart, event)
    before = length(session.messages)
    observe!(session, kind, event)
    foreach(message -> recordmessage!(session, message), @view session.messages[before+1:end])
end
function event!(session, kind::LiveJSON.MessageEnd, event)
    cancelled!(session.stream, J.turnstate(session.agent), LiveJSON.role(event.message))
    observe!(session, kind, event)
    completed!(session, LiveJSON.role(event.message), event.message)
    recordmessage!(session, LiveJSON.role(event.message))
end
event!(session, kind::LiveJSON.Event, event) = observe!(session, kind, event)

cancelled!(stream, turn, role) = nothing
function cancelled!(stream, ::J.Cancelled, ::LiveJSON.AssistantRole)
    message = Dict{String, Any}("role" => "assistant", "content" => nothing)
    stream.completion = J.Completion(message, stream.used, "cancelled", J.Unfinished(), "Request cancelled")
    nothing
end

function observe!(session, kind, event)
    before = length(session.stream.messages)
    LiveJSON.observe!(session.stream, kind, event)
    append!(session.messages, @view session.stream.messages[before+1:end])
    nothing
end
completed!(session, role::LiveJSON.Role, raw) = nothing
function completed!(session, ::LiveJSON.AssistantRole, raw)
    recordprice!(session, session.stream.used)
    session.lastcontent = finaltext(get(raw, "content", nothing))
    nothing
end
finaltext(::Nothing) = ""
finaltext(text::AbstractString) = String(text)

function failedturn!(session, finish)
    lock(session.lock) do
        before = length(session.stream.messages)
        LiveJSON.failedturn!(session.stream, finish)
        append!(session.messages, @view session.stream.messages[before+1:end])
        foreach(message -> recordmessage!(session, message), @view session.stream.messages[before+1:end])
        session.lastcontent = ""
    end
end
