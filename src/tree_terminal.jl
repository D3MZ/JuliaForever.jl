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
tree!(terminal::Terminal, agent::Agent, history::History.SQLite, tree::History.Tree, choice::Union{TreeTerminal.Move, TreeTerminal.Edit}, snapshot) = tree!(terminal, agent, history, tree, choice, History.branch!(tree, choice.node), snapshot)
tree!(terminal::Terminal, agent::Agent, history::History.SQLite, tree::History.Tree, choice::Union{TreeTerminal.Move, TreeTerminal.Edit}, rejected::History.Rejected, snapshot) = (agent, history, result!(terminal, rejected))
tree!(terminal::Terminal, agent::Agent, history::History.SQLite, tree::History.Tree, choice::Union{TreeTerminal.Move, TreeTerminal.Edit}, selected::Integer, snapshot) = tree!(terminal, agent, tree, choice, selected, snapshot)
tree!(terminal::Terminal, agent::Agent, history::History.Tree, ::TreeTerminal.Cancelled, snapshot) = (agent, history, 0)
tree!(terminal::Terminal, agent::Agent, history::History.Tree, rejected::History.Rejected, snapshot) = (agent, history, result!(terminal, rejected))

function tree!(terminal::Terminal, agent::Agent, history::History.Tree, choice::Union{TreeTerminal.Move, TreeTerminal.Edit}, snapshot)
    tree!(terminal, agent, history, choice, History.branch!(history, choice.node), snapshot)
end

tree!(terminal::Terminal, agent::Agent, history::History.Tree, choice::Union{TreeTerminal.Move, TreeTerminal.Edit}, rejected::History.Rejected, snapshot) = (agent, history, result!(terminal, rejected))

function tree!(terminal::Terminal, agent::Agent, history::History.Tree, choice::Union{TreeTerminal.Move, TreeTerminal.Edit}, selected::Integer, snapshot)
    restored = Agent(agent.provider, agent.tools, Dict{String, Any}[]; history)
    tree!(terminal, agent, history, choice, restored, snapshot)
end

tree!(terminal::Terminal, agent::Agent, history::History.Tree, choice::Union{TreeTerminal.Move, TreeTerminal.Edit}, restored::Agent, snapshot) = tree!(terminal, agent, history, choice, restored, restored.fault, snapshot)
tree!(terminal::Terminal, agent::Agent, history::History.Tree, choice::Union{TreeTerminal.Move, TreeTerminal.Edit}, restored::Agent, rejected::History.Rejected, snapshot) = (agent, history, result!(terminal, rejected))
tree!(terminal::Terminal, agent::Agent, history::History.Tree, ::TreeTerminal.Move, restored::Agent, ::Nothing, snapshot) = (restored, history, 0)
tree!(terminal::Terminal, agent::Agent, history::History.Tree, choice::TreeTerminal.Edit, restored::Agent, ::Nothing, snapshot) = (restored, history, run!(terminal, restored, choice.text, snapshot))
