function restore!(session, agent)
    messages = getfield(agent.state, :messages)
    length(messages) <= length(getfield(agent.initial, :messages)) && return session
    session.statistics = UnavailableStatistics()
    for value in messages
        restore!(session, value)
    end
    session
end

restore!(session, value::J.Conversation.Message) = nothing
restore!(session, value::Union{J.Conversation.User, J.Conversation.ImageUser, J.Conversation.ToolMessage, J.Conversation.Summary, J.Conversation.SkillContext}) = restore!(session, convert(Dict{String, Any}, value))
restore!(session, value::J.Conversation.RawMessage) = restore!(session, value.value)
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
    session.lastcontent = value.content
    push!(session.messages, message)
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
function event!(session, kind::LiveJSON.MessageStart, event)
    queues!(session)
    observe!(session, kind, event)
end
function event!(session, kind::LiveJSON.MessageEnd, event)
    cancelled!(session.stream, J.turnstate(session.agent), LiveJSON.role(event.message))
    observe!(session, kind, event)
    completed!(session, LiveJSON.role(event.message), event.message)
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
        session.lastcontent = ""
    end
end
