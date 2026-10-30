function restoreentries!(session)
    empty!(session.entries)
    foreach(event -> collectentry!(session.entries, event), getfield(session.agent, :events))
    session.entryleaf = entryleaf(session.entries)
    isempty(session.entries) || return restorethinking!(session, session.terminal.mode.thinking)
    initialmodel!(session, session.agent.provider)
    entrysaved!(session, recordentry!(session, J.Conversation.ThinkingEntry(session.thinking)))
    nothing
end

collectentry!(entries, event) = nothing
collectentry!(entries, event::J.Conversation.SessionRecord) = (push!(entries, event); nothing)
entryleaf(entries) = isempty(entries) ? nothing : last(entries).id
initialmodel!(session, ::J.UnconfiguredProvider) = nothing
function initialmodel!(session, provider)
    entry = J.Conversation.ModelEntry(LiveJSON.providername(session.terminal.mode, provider), provider.model)
    entrysaved!(session, recordentry!(session, entry))
end

function recordentry!(session, entry::J.Conversation.SessionEntry)
    lock(session.lock) do
        lock(session.agent.lock) do
            id = bytes2hex(rand(UInt8, 8))
            parent = session.entryleaf
            timestamp = Dates.format(Dates.now(Dates.UTC), dateformat"yyyy-mm-ddTHH:MM:SS.sss") * "Z"
            result, _ = J.transition!(revision -> J.Conversation.SessionRecord(revision, id, parent, timestamp, entry), session.agent)
            recordedentry!(session, result)
        end
    end
end
recordedentry!(session, rejected::J.History.Rejected) = rejected
recordedentry!(session, result::J.Kernel.Applied) = recordedentry!(session, last(getfield(session.agent, :events)))
function recordedentry!(session, entry::J.Conversation.SessionRecord)
    push!(session.entries, entry)
    session.entryleaf = entry.id
    nothing
end
entrysaved!(session, ::Nothing) = nothing
entrysaved!(session, rejected::J.History.Rejected) = println(session.terminal.diagnostics, "Could not save session entry: ", rejected.reason)

recordmessage!(session, role::LiveJSON.Role) = nothing
function recordmessage!(session, role::Union{LiveJSON.UserRole, LiveJSON.AssistantRole, LiveJSON.ToolRole})
    recordmessage!(session, last(session.messages))
end
function recordmessage!(session, value::AbstractDict)
    message = JSON3.read(codeunits(JSON3.write(value)), Dict{String, Any})
    entrysaved!(session, recordentry!(session, J.Conversation.MessageEntry(message)))
end

backfill!(session, ::LiveJSON.RecordedMessages) = nothing
function backfill!(session, ::LiveJSON.NoRecordedMessages)
    foreach(message -> backfillmessage!(session, get(backfillroles, message["role"], nothing), message), session.messages)
    nothing
end
backfillmessage!(session, ::Nothing, message) = nothing
backfillmessage!(session, ::LiveJSON.Role, message) = recordmessage!(session, message)
const backfillroles = Dict("system" => LiveJSON.SystemRole(), "user" => LiveJSON.UserRole(), "assistant" => LiveJSON.AssistantRole(), "toolResult" => LiveJSON.ToolRole(), "bashExecution" => LiveJSON.OtherRole())

entryfields(entry::J.Conversation.ModelEntry) = (; type="model_change", provider=entry.provider, modelId=entry.model)
entryfields(entry::J.Conversation.ThinkingEntry) = (; type="thinking_level_change", thinkingLevel=entry.level)
entryfields(entry::J.Conversation.MessageEntry) = (; type="message", message=entry.message)
entryfields(entry::J.Conversation.NameEntry) = (; type="session_info", name=entry.name)
function entryfields(entry::J.Conversation.CompactionEntry)
    fields = LiveJSON.compactiondata(entry)
    delete!(fields, "estimatedTokensAfter")
    fields["type"] = "compaction"
    fields
end
function entryvalue(record::J.Conversation.SessionRecord)
    value = Dict{String, Any}("id" => record.id, "parentId" => record.parent, "timestamp" => record.timestamp)
    for (key, field) in pairs(entryfields(record.entry))
        value[String(key)] = field
    end
    value
end

function allentries(session)
    tree = J.sessiontree(session.store[])
    allentries(tree, session.entries)
end
allentries(rejected::J.History.Rejected, entries) = copy(entries)
allentries(tree::J.History.Tree, entries) = allentries(J.History.entries(tree), entries)
function allentries(rows::Vector, fallback)
    entries = J.Conversation.SessionRecordValue[]
    for row in rows
        collectentry!(entries, J.History.treeevent(row.batch))
    end
    entries
end

handle!(session, command::GetEntries) = lock(() -> entriesresponse(session, allentries(session), command.since), session.lock)
entriesresponse(session, entries, ::Nothing) = Success((; data=(; entries=entryvalue.(entries), leafId=session.entryleaf)))
function entriesresponse(session, entries, since::String)
    index = findfirst(entry -> entry.id == since, entries)
    entriesafter(session, entries, since, index)
end
entriesafter(session, entries, since, ::Nothing) = Failure("Entry not found: " * since)
entriesafter(session, entries, since, index::Int) = Success((; data=(; entries=entryvalue.(@view entries[index+1:end]), leafId=session.entryleaf)))

struct EntryNode
    entry::Dict{String, Any}
    children::Vector{EntryNode}
end
JSON3.StructTypes.StructType(::Type{EntryNode}) = JSON3.StructTypes.Struct()

function entrytree(entries)
    roots = EntryNode[]
    nodes = Dict{String, EntryNode}()
    for entry in entries
        node = EntryNode(entryvalue(entry), EntryNode[])
        nodes[entry.id] = node
        attachentry!(roots, get(nodes, entry.parent, nothing), node)
    end
    roots
end
attachentry!(roots, ::Nothing, node) = push!(roots, node)
attachentry!(roots, parent::EntryNode, node) = push!(parent.children, node)
handle!(session, ::GetTree) = lock(() -> Success((; data=(; tree=entrytree(allentries(session)), leafId=session.entryleaf))), session.lock)
