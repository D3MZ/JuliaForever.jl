precompact!(agent, callback) = precompact!(agent, callback, get(task_local_storage(), :jf_pre_compaction, nothing))
precompact!(agent, callback, ::Nothing) = nothing
precompact!(agent, callback, policy::Tuple) = precompact!(agent, callback, policy...)
precompact!(agent, callback, settings, summarize) = nothing
function precompact!(agent, callback, settings::UsageCompaction, summarize)
    precompact!(agent, callback, settings, summarize, sync!(agent))
end
precompact!(agent, callback, settings, summarize, rejected::History.Rejected) = rejected
function precompact!(agent, callback, settings, summarize, ::Nothing)
    tokens = lock(() -> preestimate(agent), agent.lock)
    prethreshold!(agent, callback, settings, summarize, tokens)
end
prethreshold!(agent, callback, settings, summarize, ::Nothing) = nothing
function prethreshold!(agent, callback, settings, summarize, tokens::Int)
    tokens > 0 && settings.context_window > 0 && tokens > settings.context_window - settings.reserve_tokens || return nothing
    autoplan!(agent, summarize, callback, settings.retention, nothing)
end

struct InitialSummary end
struct EditedContext end
initialreply(pair::Tuple, message::Conversation.Message) = pair
initialreply(pair::Tuple, message::Conversation.Summary) = InitialSummary()
initialreply(pair::Tuple, message::Conversation.Assistant) = (message, usefulreply(last(pair), message))
initialreply(pair::Tuple, message::Conversation.RawMessage) = get(initialroles, get(message.value, "role", ""), initialother)(pair)
initialother(pair) = pair
initialassistant(pair) = (EditedContext(), nothing)
const initialroles = Dict("assistant" => initialassistant)
initialreply(summary::InitialSummary, message::Conversation.Message) = summary
initialpair(pair::Tuple) = pair
initialpair(::InitialSummary) = (nothing, nothing)

function preestimate(agent)
    initial = foldl(initialreply, getfield(agent.initial, :messages); init=(nothing, nothing))
    replies = foldl(previousreply, getfield(agent, :events); init=initialpair(initial))
    preestimate(replies, getfield(agent.state, :messages))
end
previousreply(pair, event) = pair
previousreply(pair, event::Conversation.SystemUpdate) = (editedreply(first(pair)), nothing)
previousreply(pair, event::Conversation.History) = previoushistory(event.compaction, event.messages)
previoushistory(info::Conversation.ResponseInfo, messages) = (nothing, nothing)
function previoushistory(::Nothing, messages)
    pair = initialpair(foldl(initialreply, messages; init=(nothing, nothing)))
    (editedreply(first(pair)), nothing)
end
editedreply(::Nothing) = nothing
editedreply(::Conversation.Assistant) = EditedContext()
editedreply(value::EditedContext) = value
function previousreply(pair, event::Kernel.Observe{Conversation.ModelReply})
    message = event.observation.message
    (message, usefulreply(last(pair), message))
end
usefulreply(previous, message) = usefulreply(previous, message, getfield(message, :status), message.info)
usefulreply(previous, message, status, info) = previous
usefulreply(previous, message, ::Finished, info::Conversation.ResponseInfo) = usefulreply(previous, message, info.usage)
usefulreply(previous, message, ::Nothing) = previous
usefulreply(previous, message, usage::Usage) = contexttokens(usage) > 0 ? message : previous

preestimate(pair::Tuple, messages) = preestimate(first(pair), last(pair), messages)
preestimate(::Nothing, anchor, messages) = nothing
preestimate(::EditedContext, anchor, messages) = preestimated(nothing, messages)
preestimate(message::Conversation.Assistant, anchor, messages) = preestimate(message, anchor, messages, getfield(message, :status), message.info)
preestimate(message, anchor, messages, status, info) = preestimated(anchor, messages)
preestimate(message, anchor, messages, ::Finished, info::Conversation.ResponseInfo) = preestimate(message, anchor, messages, info.usage)
preestimate(message, anchor, messages, ::Nothing) = preestimated(anchor, messages)
function preestimate(message, anchor, messages, usage::Usage)
    tokens = contexttokens(usage)
    tokens > 0 ? tokens : preestimated(anchor, messages)
end

preestimated(::Nothing, messages) = sum(pretoken, messages; init=0)
function preestimated(anchor::Conversation.Assistant, messages)
    index = findlast(isequal(anchor), messages)
    preestimated(anchor, messages, index)
end
preestimated(anchor, messages, ::Nothing) = preestimated(nothing, messages)
function preestimated(anchor, messages, index::Int)
    contexttokens(anchor.info.usage) + sum(pretoken, @view(messages[index+1:end]); init=0)
end

pretoken(message::Conversation.Message) = cld(preunits(message), 4)
preunits(message::Conversation.Message) = recentunits(message)
preunits(message::Conversation.Summary) = ContextEstimates.units(message.content)
preunits(message::Conversation.SkillContext) = ContextEstimates.units(message.content)
preunits(message::Conversation.RawMessage) = get(preunitroles, get(message.value, "role", ""), recentother)(message.value)
presystem(value) = ContextEstimates.units(ContextEstimates.systemtext(value)) + pretools(get(value, "toolsAdded", nothing)) + pretools(get(value, "toolsRemoved", nothing))
pretools(::Nothing) = 0
pretools(tools) = ContextEstimates.units(JSON3.write(tools))
const preunitroles = merge(recentroles, Dict("system" => presystem))
