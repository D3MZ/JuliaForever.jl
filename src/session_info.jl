module SessionInfo

using Printf
import ..JuliaForever as J

abstract type UsageTotal end
struct UnknownUsage <: UsageTotal end
struct KnownUsage <: UsageTotal
    input::Int
    output::Int
    cache_read::Int
    cache_write::Int
    cost::Union{Nothing, Float64}
end
KnownUsage() = KnownUsage(0, 0, 0, 0, 0.0)

mutable struct Counts
    user::Int
    assistant::Int
    calls::Int
    results::Int
    total::Int
    usage::UsageTotal
end
Counts() = Counts(0, 0, 0, 0, 0, KnownUsage())

addcost(::Nothing, cost) = nothing
addcost(cost, ::Nothing) = nothing
addcost(::Nothing, ::Nothing) = nothing
addcost(a::Float64, b::Float64) = a + b
addusage(::UnknownUsage, value) = UnknownUsage()
addusage(usage::KnownUsage, ::Nothing) = UnknownUsage()
addusage(usage::KnownUsage, info::J.Conversation.ResponseInfo) = addusage(usage, info.usage)
function addusage(total::KnownUsage, usage::J.Usage)
    KnownUsage(total.input + usage.input, total.output + usage.output, total.cache_read + usage.cache_read, total.cache_write + usage.cache_write, addcost(total.cost, usage.cost))
end

count!(counts, message::J.Conversation.Message) = nothing
function count!(counts, message::Union{J.Conversation.User, J.Conversation.ImageUser})
    counts.total += 1
    counts.user += 1
    nothing
end
function count!(counts, message::J.Conversation.Assistant)
    counts.total += 1
    counts.assistant += 1
    counts.calls += length(message.calls)
    nothing
end
function count!(counts, message::J.Conversation.ToolMessage)
    counts.total += 1
    counts.results += 1
    nothing
end
count!(counts, message::J.Conversation.BashMessage) = (counts.total += 1; nothing)
count!(counts, message::J.Conversation.RawMessage) = count!(counts, J.LiveJSON.role(message.value), message.value)
count!(counts, role::J.LiveJSON.Role, raw) = nothing
count!(counts, ::J.LiveJSON.UserRole, raw) = (counts.total += 1; counts.user += 1; nothing)
count!(counts, ::J.LiveJSON.ToolRole, raw) = (counts.total += 1; counts.results += 1; nothing)
function count!(counts, ::J.LiveJSON.AssistantRole, raw)
    counts.total += 1
    counts.assistant += 1
    counts.calls += length(get(raw, "tool_calls", []))
    nothing
end

initial!(counts, message::J.Conversation.Message) = count!(counts, message)
function initial!(counts, message::J.Conversation.Assistant)
    count!(counts, message)
    counts.usage = addusage(counts.usage, message.info)
    nothing
end
function initial!(counts, message::J.Conversation.RawMessage)
    count!(counts, message)
    initialusage!(counts, J.LiveJSON.role(message.value))
end
initialusage!(counts, role::J.LiveJSON.Role) = nothing
initialusage!(counts, ::J.LiveJSON.AssistantRole) = (counts.usage = UnknownUsage(); nothing)

observed!(counts, event::J.Kernel.Event) = nothing
function observed!(counts, event::J.Kernel.Observe{J.Conversation.ModelReply})
    message = event.observation.message
    counts.usage = addusage(counts.usage, message.info)
    incomplete!(counts, message, getfield(message, :status))
end
incomplete!(counts, message, ::J.Finished) = nothing
incomplete!(counts, message, ::J.Unfinished) = count!(counts, message)

added!(counts, before, after, ::J.Conversation.History) = nothing
function added!(counts, before, after, event::J.Kernel.Event)
    previous = getfield(before, :messages)
    current = getfield(after, :messages)
    foreach(message -> count!(counts, message), @view current[length(previous) + 1:end])
    nothing
end

function collectafter!(counts, before, after::J.Conversation.State, event::J.Kernel.Event)
    added!(counts, before, after, event)
    observed!(counts, event)
    counts
end
collect!(counts::Counts, before::J.History.Rejected, after, event) = before
collect!(counts::Counts, before::J.Conversation.State, after, event) = collectafter!(counts, before, after, event)
collectafter!(counts, before, after::J.History.Rejected, event) = after
collectafter!(counts, before, after::J.Conversation.State, event::J.History.Rejected) = event
collect!(rejected::J.History.Rejected, before, after, event) = rejected

function counts(agent, history::J.History.Tree)
    counts(agent, J.History.branches(history))
end
counts(agent, history::Union{J.History.SQLite, J.History.Memory}) = counts(agent, J.History.Tree(history))
counts(agent, ::Nothing) = eventcounts(getfield(agent, :events), agent.initial)
counts(agent, history::J.History.Store) = eventcounts(getfield(agent, :events), agent.initial)
counts(agent, rejected::J.History.Rejected) = rejected
function counts(agent, branches::Vector)
    isempty(branches) && return eventcounts(getfield(agent, :events), agent.initial)
    branchcounts(branches, first(branches).state)
end
branchcounts(branches, rejected::J.History.Rejected) = rejected
function branchcounts(branches, initial::J.Conversation.State)
    totals = Counts()
    foreach(message -> initial!(totals, message), getfield(initial, :messages))
    result = totals
    for branch in @view branches[2:end]
        result = collect!(result, branches[branch.parent].state, branch.state, J.History.treeevent(branch.batch))
    end
    result
end
function eventcounts(events::Vector, initial::J.Conversation.State)
    totals = Counts()
    foreach(message -> initial!(totals, message), getfield(initial, :messages))
    state = initial
    result = totals
    for event in events
        stepped = J.Kernel.step(state, event)
        result = collectstep!(result, state, event, stepped)
        state = stepstate(state, stepped)
    end
    result
end
collectstep!(result, state, event, stepped) = J.History.Rejected(:invalid_record)
collectstep!(result, state, event, stepped::J.Kernel.Applied) = collect!(result, state, stepped.state, event)
stepstate(state, stepped) = state
stepstate(state, stepped::J.Kernel.Applied) = stepped.state

struct Report{S, N}
    counts::Counts
    source::S
    name::N
    id::String
end
report(agent, history) = report(agent, history, counts(agent, history), J.SessionCatalog.sessionname(history))
report(agent, history, rejected::J.History.Rejected, name) = rejected
report(agent, history, counts::Counts, rejected::J.History.Rejected) = rejected
report(agent, history, counts::Counts, name) = Report(counts, J.exportsource(history), name, J.exportid(history, agent))

number(value::Int) = replace(string(value), r"(?<=\d)(?=(?:\d{3})+(?!\d))" => ",")
file(::J.MemoryExport) = "In-memory"
file(::J.UnsavedExport) = "Not saved yet"
file(path::String) = path
name!(io, ::Nothing, clean) = nothing
name!(io, value::String, clean) = println(io, "Name: ", clean(value))

function printinfo(io, report::Report, clean)
    counts = report.counts
    println(io, "Session Info\n")
    name!(io, report.name, clean)
    println(io, "File: ", clean(file(report.source)))
    println(io, "ID: ", report.id, "\n")
    println(io, "Messages")
    println(io, "Total: ", number(counts.total))
    println(io, "User: ", number(counts.user))
    println(io, "Assistant: ", number(counts.assistant))
    println(io, "Tools: ", number(counts.calls), " calls, ", number(counts.results), " results\n")
    printusage(io, counts.usage)
    nothing
end
function printusage(io, usage::UnknownUsage)
    println(io, "Tokens\nInput: Unavailable\nOutput: Unavailable\nTotal: Unavailable\n\nCost\nTotal: Unavailable")
end
function printusage(io, usage::KnownUsage)
    input = usage.input + usage.cache_read + usage.cache_write
    println(io, "Tokens")
    println(io, "Input: ", number(input))
    if usage.cache_read + usage.cache_write > 0
        @printf(io, "Cached: %s (%.1f%%)\n", number(usage.cache_read), 100 * usage.cache_read / input)
        print(io, "Uncached: ", number(usage.input + usage.cache_write))
        cachewrite!(io, usage.cache_write)
    end
    println(io, "Output: ", number(usage.output))
    println(io, "Total: ", number(input + usage.output), "\n")
    println(io, "Cost")
    printcost(io, usage.cost)
end
function cachewrite!(io, value::Int)
    value > 0 && print(io, " (", number(value), " written to cache)")
    println(io)
end
printcost(io, ::Nothing) = println(io, "Total: Unavailable")
printcost(io, cost::Float64) = @printf(io, "Total: \$%.3f\n", cost)

function J.command!(::J.SessionCommand, terminal, agent, history, input, directory, snapshot)
    result = lock(agent.lock) do
        report(agent, history)
    end
    show!(terminal, agent, history, result)
end
show!(terminal, agent, history, rejected::J.History.Rejected) = (agent, history, J.result!(terminal, rejected))
function show!(terminal, agent, history, report::Report)
    printinfo(terminal.diagnostics, report, text -> J.LiveTerminal.clean(J.redact(terminal, text)))
    flush(terminal.diagnostics)
    agent, history, 0
end

end
