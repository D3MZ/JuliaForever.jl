struct ForkEntry
    id::String
    choice::Union{J.TreeTerminal.InputFork, J.TreeTerminal.QueuedFork, J.TreeTerminal.ImageFork}
end

forks(session) = forks(J.sessiontree(session.store[]))
forks(rejected::J.History.Rejected) = rejected
forks(tree::J.History.Tree) = forks(tree, J.History.branches(tree))
forks(tree, rejected::J.History.Rejected) = rejected
function forks(tree, branches::Vector)
    entries = ForkEntry[]
    ids = forkids(branches)
    for item in branches
        choices = Union{J.TreeTerminal.InputFork, J.TreeTerminal.QueuedFork, J.TreeTerminal.ImageFork}[]
        J.TreeTerminal.forkitem!(choices, item, J.History.treeevent(item.batch), branches)
        for (index, choice) in enumerate(choices)
            native = string(item.id, ":", index)
            push!(entries, ForkEntry(get(ids, native, native), choice))
        end
    end
    (; tree, entries)
end

function forkids(branches)
    ids = Dict{String, String}()
    for item in branches
        forkid!(ids, item, J.History.treeevent(item.batch), branches)
    end
    ids
end
forkid!(ids, item, event, branches) = nothing
forkid!(ids, item, event::J.Conversation.SessionRecord, branches) = forkid!(ids, item, event, event.entry, branches)
forkid!(ids, item, event, entry::J.Conversation.SessionEntry, branches) = nothing
forkid!(ids, item, event, entry::J.Conversation.MessageEntry, branches) = forkid!(ids, item, event, entry, LiveJSON.role(entry.message), branches)
forkid!(ids, item, event, entry, role::LiveJSON.Role, branches) = nothing
function forkid!(ids, item, event, entry, ::LiveJSON.UserRole, branches)
    text = forktext(get(entry.message, "content", ""))
    associatefork!(ids, event.id, findfork(branches, item.parent, text, ids))
end
forktext(content::AbstractString) = String(content)
forktext(content::AbstractVector) = join(get(block, "text", "") for block in content)
forktext(content) = ""
associatefork!(ids, entry, ::Nothing) = nothing
associatefork!(ids, entry, native::String) = (ids[native] = entry; nothing)
findfork(branches, node::Int, text, ids) = findfork(branches, node, text, ids, get(branches, node, nothing))
findfork(branches, node, text, ids, ::Nothing) = nothing
function findfork(branches, node, text, ids, item::NamedTuple)
    choices = Union{J.TreeTerminal.InputFork, J.TreeTerminal.QueuedFork, J.TreeTerminal.ImageFork}[]
    J.TreeTerminal.forkitem!(choices, item, J.History.treeevent(item.batch), branches)
    index = findfirst(index -> choices[index].text == text && !haskey(ids, string(item.id, ":", index)), eachindex(choices))
    foundfork(branches, item, text, ids, index)
end
foundfork(branches, item, text, ids, ::Nothing) = findfork(branches, item.parent, text, ids)
foundfork(branches, item, text, ids, index::Int) = string(item.id, ":", index)

handle!(session, ::GetForkMessages) = forklist(J.attempt(() -> forks(session)))
forklist(rejected::J.History.Rejected) = Failure(string(rejected.reason))
forklist(failure::J.ToolFailure) = Failure(failure.text)
function forklist(result::NamedTuple)
    Success((; data=(; messages=[(; entryId=entry.id, text=entry.choice.text) for entry in result.entries])))
end

handle!(session, command::ForkSession) = forkchecked!(session, command, J.sourcecheck!(session.terminal, session.agent, session.store[]))
forkchecked!(session, command, blocked::J.PendingInputs) = Failure("Session has pending inputs")
forkchecked!(session, command, rejected::J.History.Rejected) = Failure(string(rejected.reason))
forkchecked!(session, command, ::Nothing) = fork!(session, command, J.attempt(() -> forks(session)))
fork!(session, command, failure::J.ToolFailure) = Failure(J.redact(session.terminal, failure.text))
fork!(session, command, rejected::J.History.Rejected) = Failure(string(rejected.reason))
function fork!(session, command, result::NamedTuple)
    choices = Dict(entry.id => entry.choice for entry in result.entries)
    fork!(session, command, result.tree, get(choices, command.id, nothing))
end
fork!(session, command, tree, ::Nothing) = Failure("Entry not found: " * command.id)
function fork!(session, command, tree, choice::J.TreeTerminal.ForkChoice)
    draft = Ref("")
    agent, history, status = J.fork!(session.terminal, session.agent, session.store[], session.directory, draft, tree, choice)
    forkresult!(session, agent, history, choice, get(newstatuses, status, nothing))
end
forkresult!(session, agent, history, choice, ::Nothing) = Failure("Could not fork the session")
function forkresult!(session, agent, history, choice, ::SessionStarted)
    rebind!(session, agent, history, ResumeBinding())
    lock(session.lock) do
        append!(session.messages, session.stream.initial)
        empty!(session.stream.initial)
    end
    Success((; data=(; text=choice.text, cancelled=false)))
end
