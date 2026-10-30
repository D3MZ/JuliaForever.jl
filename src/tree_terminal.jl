module TreeTerminal

import ..History as H
import ..Conversation as C

abstract type Choice end
struct UserChoice <: Choice
    node::Int
    text::String
    depth::Int
end
struct AnswerChoice <: Choice
    node::Int
    text::String
    depth::Int
end

abstract type ForkChoice <: Choice end
struct InputFork <: ForkChoice
    node::Int
    text::String
end
struct QueuedFork <: ForkChoice
    node::Int
    text::String
end

struct Cancelled end
struct Move
    node::Int
end
struct Edit
    node::Int
    text::String
end

depth(event) = 0
depth(::C.Input) = 1
add!(choices, item, level, event) = nothing

function add!(choices, item, level, event::C.Input)
    push!(choices, UserChoice(item.parent, event.text, level))
end

add!(choices, item, level, event::C.Advance) = answer!(choices, item, level, item.state)
answer!(choices, item, level, rejected::H.Rejected) = nothing
answer!(choices, item, level, state::C.State) = answer!(choices, item, level, state, H.ready(state))
answer!(choices, item, level, state, rejected::H.Rejected) = nothing

function answer!(choices, item, level, state::C.State, ::Nothing)
    isempty(state.messages) && return nothing
    answer!(choices, item, level, last(state.messages))
end

answer!(choices, item, level, message) = nothing
answer!(choices, item, level, message::C.Assistant) = answer!(choices, item, level, message.content)
answer!(choices, item, level, ::Nothing) = nothing
answer!(choices, item, level, text::String) = push!(choices, AnswerChoice(item.id, text, level))

function choices(branches::Vector)
    items = Choice[]
    levels = zeros(Int, length(branches))
    for item in branches
        event = H.treeevent(item.batch)
        levels[item.id] = (item.parent == 0 ? 0 : levels[item.parent]) + depth(event)
        add!(items, item, levels[item.id], event)
    end
    items
end

label(choice::UserChoice) = "user"
label(choice::AnswerChoice) = "assistant"

function clean(text)
    value = strip(replace(text, r"[\x00-\x1f\x7f]" => " "))
    first(value, min(length(value), 100))
end

choose(tree::H.Tree, input, output, redact=identity) = choose(H.branches(tree), input, output, redact)
choose(rejected::H.Rejected, input, output, redact=identity) = rejected

function choose(branches::Vector, input, output, redact=identity)
    items = choices(branches)
    if isempty(items)
        println(output, "No session messages.")
        return Cancelled()
    end
    for (index, item) in enumerate(items)
        println(output, "[", index, "] ", repeat("  ", max(item.depth - 1, 0)), label(item), ": ", clean(redact(item.text)))
    end
    pick(items, input, output, redact)
end

fork(tree::H.Tree, input, output, redact=identity) = fork(H.branches(tree), input, output, redact)
fork(rejected::H.Rejected, input, output, redact=identity) = rejected
function fork(branches::Vector, input, output, redact=identity)
    items = ForkChoice[]
    for item in branches
        forkitem!(items, item, H.treeevent(item.batch), branches)
    end
    if isempty(items)
        println(output, "No messages to fork from.")
        return Cancelled()
    end
    for (index, item) in enumerate(items)
        println(output, "[", index, "] ", clean(redact(item.text)))
    end
    pick(items, input, output, redact)
end
forkitem!(items, item, event, branches) = nothing
forkitem!(items, item, event::C.Input, branches) = forkitem!(items, InputFork(item.parent, event.text))
forkitem!(items, item, event::C.Advance, branches) = forkadded!(items, item.parent, branches[item.parent].state, item.state)
forkitem!(items, item::ForkChoice) = isempty(strip(item.text)) ? nothing : push!(items, item)
forkadded!(items, node, before, after) = nothing
function forkadded!(items, node, before::C.State, after::C.State)
    previous = getfield(before, :messages)
    messages = getfield(after, :messages)
    for message in Iterators.drop(messages, length(previous))
        forkmessage!(items, node, message)
    end
end
forkmessage!(items, node, message) = nothing
forkmessage!(items, node, message::C.User) = forkitem!(items, QueuedFork(node, message.content))

function pick(items, input, output, redact)
    print(output, "Choose a message (number or q): ")
    flush(output)
    eof(input) && return Cancelled()
    value = strip(readline(input))
    value in ("", "q") && return Cancelled()
    pick(items, input, output, tryparse(Int, value), redact)
end

function pick(items, input, output, ::Nothing, redact)
    println(output, "Enter a message number or q.")
    pick(items, input, output, redact)
end

function pick(items, input, output, index::Int, redact)
    1 <= index <= length(items) && return select(items[index], input, output, redact)
    println(output, "Enter a message number or q.")
    pick(items, input, output, redact)
end

select(choice::AnswerChoice, input, output, redact) = Move(choice.node)
select(choice::ForkChoice, input, output, redact) = choice

function select(choice::UserChoice, input, output, redact)
    print(output, "Message [", clean(redact(choice.text)), "] (empty keeps it, /cancel aborts): ")
    flush(output)
    eof(input) && return Cancelled()
    text = readline(input)
    text == "/cancel" && return Cancelled()
    Edit(choice.node, isempty(text) ? choice.text : text)
end

end

function tree!(terminal::Terminal, agent::Agent, history, input::IO, snapshot)
    println(terminal.diagnostics, "Session tree is unavailable for this history.")
    agent, history, 1
end

tree!(terminal::Terminal, agent::Agent, history::History.Tree, input::IO, snapshot) = tree!(terminal, agent, history, TreeTerminal.choose(history, input, terminal.diagnostics, text -> redact(terminal, text)), snapshot)
tree!(terminal::Terminal, agent::Agent, history::History.SQLite, input::IO, snapshot) = tree!(terminal, agent, history, input, History.Tree(history), snapshot)
tree!(terminal::Terminal, agent::Agent, history::History.SQLite, input::IO, rejected::History.Rejected, snapshot) = (agent, history, result!(terminal, rejected))
tree!(terminal::Terminal, agent::Agent, history::History.SQLite, input::IO, tree::History.Tree, snapshot) = tree!(terminal, agent, history, tree, TreeTerminal.choose(tree, input, terminal.diagnostics, text -> redact(terminal, text)), snapshot)
tree!(terminal::Terminal, agent::Agent, history::History.SQLite, tree::History.Tree, ::TreeTerminal.Cancelled, snapshot) = (agent, history, 0)
tree!(terminal::Terminal, agent::Agent, history::History.SQLite, tree::History.Tree, rejected::History.Rejected, snapshot) = (agent, history, result!(terminal, rejected))
tree!(terminal::Terminal, agent::Agent, history::History.SQLite, tree::History.Tree, choice::Union{TreeTerminal.Move, TreeTerminal.Edit}, snapshot) = tree!(terminal, agent, history, tree, choice, selectbranch!(terminal, agent, tree, choice), snapshot)
tree!(terminal::Terminal, agent::Agent, history::History.SQLite, tree::History.Tree, choice::Union{TreeTerminal.Move, TreeTerminal.Edit}, rejected::History.Rejected, snapshot) = (agent, history, result!(terminal, rejected))
tree!(terminal::Terminal, agent::Agent, history::History.SQLite, tree::History.Tree, choice::Union{TreeTerminal.Move, TreeTerminal.Edit}, ::PendingInputs, snapshot) = (agent, history, 1)
tree!(terminal::Terminal, agent::Agent, history::History.SQLite, tree::History.Tree, choice::Union{TreeTerminal.Move, TreeTerminal.Edit}, selected::Integer, snapshot) = tree!(terminal, agent, tree, choice, selected, snapshot)
tree!(terminal::Terminal, agent::Agent, history::History.Tree, ::TreeTerminal.Cancelled, snapshot) = (agent, history, 0)
tree!(terminal::Terminal, agent::Agent, history::History.Tree, rejected::History.Rejected, snapshot) = (agent, history, result!(terminal, rejected))

function tree!(terminal::Terminal, agent::Agent, history::History.Tree, choice::Union{TreeTerminal.Move, TreeTerminal.Edit}, snapshot)
    tree!(terminal, agent, history, choice, selectbranch!(terminal, agent, history, choice), snapshot)
end

tree!(terminal::Terminal, agent::Agent, history::History.Tree, choice::Union{TreeTerminal.Move, TreeTerminal.Edit}, rejected::History.Rejected, snapshot) = (agent, history, result!(terminal, rejected))
tree!(terminal::Terminal, agent::Agent, history::History.Tree, choice::Union{TreeTerminal.Move, TreeTerminal.Edit}, ::PendingInputs, snapshot) = (agent, history, 1)

function selectbranch!(terminal, agent, history, choice)
    lock(agent.lock) do
        selectbranch!(terminal, agent, history, choice, agent.fault)
    end
end

selectbranch!(terminal, agent, history, choice, rejected::History.Rejected) = rejected

function selectbranch!(terminal, agent, history, choice, ::Nothing)
    lock(history.lock) do
        selectbranch!(terminal, history, choice, checkqueues!(terminal, agent.state, history))
    end
end

selectbranch!(terminal, history, choice, pending::PendingInputs) = pending
selectbranch!(terminal, history, choice, ::Nothing) = selectbranch!(terminal, history, choice, History.branches(history))
selectbranch!(terminal, history, choice, rejected::History.Rejected) = rejected
selectbranch!(terminal, history, choice, branches::Vector) = selecttarget!(terminal, history, choice, branches[choice.node].state)
selecttarget!(terminal, history, choice, rejected::History.Rejected) = rejected
selecttarget!(terminal, history, choice, state::Conversation.State) = selecttarget!(terminal, history, choice, checkqueues!(terminal, state, history))
selecttarget!(terminal, history, choice, ::Nothing) = History.branch!(history, choice.node)
selecttarget!(terminal, history, choice, pending::PendingInputs) = pending

function tree!(terminal::Terminal, agent::Agent, history::History.Tree, choice::Union{TreeTerminal.Move, TreeTerminal.Edit}, selected::Integer, snapshot)
    restored = Agent(agent.provider, agent.tools, Dict{String, Any}[]; history)
    tree!(terminal, agent, history, choice, restored, snapshot)
end

tree!(terminal::Terminal, agent::Agent, history::History.Tree, choice::Union{TreeTerminal.Move, TreeTerminal.Edit}, restored::Agent, snapshot) = tree!(terminal, agent, history, choice, restored, restored.fault, snapshot)
tree!(terminal::Terminal, agent::Agent, history::History.Tree, choice::Union{TreeTerminal.Move, TreeTerminal.Edit}, restored::Agent, rejected::History.Rejected, snapshot) = (agent, history, result!(terminal, rejected))
tree!(terminal::Terminal, agent::Agent, history::History.Tree, ::TreeTerminal.Move, restored::Agent, ::Nothing, snapshot) = (restored, history, 0)
tree!(terminal::Terminal, agent::Agent, history::History.Tree, choice::TreeTerminal.Edit, restored::Agent, ::Nothing, snapshot) = (restored, history, run!(terminal, restored, choice.text, snapshot))
