abstract type TerminalCommand end
struct TreeCommand <: TerminalCommand end
struct ResumeCommand <: TerminalCommand end
struct NewCommand <: TerminalCommand end
struct ExitCommand <: TerminalCommand end
struct ShowName <: TerminalCommand end
struct SetName <: TerminalCommand
    name::String
end

const terminalcommands = Dict{String, TerminalCommand}("/tree" => TreeCommand(), "/resume" => ResumeCommand(), "/new" => NewCommand(), "/exit" => ExitCommand())
const namepattern = r"\A/name(?: +([\s\S]*))?\z"
terminalcommand(text) = terminalcommand(get(terminalcommands, text, nothing), text)
terminalcommand(command::TerminalCommand, text) = command
terminalcommand(::Nothing, text) = namecommand(match(namepattern, text))
namecommand(::Nothing) = nothing
namecommand(found::RegexMatch) = namecommand(Conversation.sessionname(something(found[1], "")))
namecommand(name::String) = isempty(name) ? ShowName() : SetName(name)

command!(::TreeCommand, terminal, agent, history, input, directory) = tree!(terminal, agent, history, input)
command!(::ResumeCommand, terminal, agent, history, input, directory) = resume!(terminal, agent, history, input, directory)
command!(::NewCommand, terminal, agent, history, input, directory) = new!(terminal, agent, history, directory)
command!(::ShowName, terminal, agent, history, input, directory) = showname!(terminal, agent, history, SessionCatalog.sessionname(history))
command!(command::SetName, terminal, agent, history, input, directory) = setname!(terminal, agent, history, command.name, name!(agent, command.name))

function showname!(terminal, agent, history, ::Nothing)
    println(terminal.diagnostics, "Usage: /name <name>")
    flush(terminal.diagnostics)
    agent, history, 0
end
function showname!(terminal, agent, history, name::String)
    println(terminal.diagnostics, "Session name: ", name)
    flush(terminal.diagnostics)
    agent, history, 0
end
showname!(terminal, agent, history, rejected::History.Rejected) = (agent, history, result!(terminal, rejected))

function setname!(terminal, agent, history, name, ::Nothing)
    println(terminal.diagnostics, "Session name set: ", name)
    flush(terminal.diagnostics)
    agent, history, 0
end
setname!(terminal, agent, history, name, rejected::History.Rejected) = (agent, history, result!(terminal, rejected))

fresh(::Nothing, directory) = History.Tree(History.Memory())
fresh(::History.Memory, directory) = History.Tree(History.Memory())
fresh(::History.Tree{<:History.Memory}, directory) = History.Tree(History.Memory())
fresh(history::History.Store, directory) = SessionCatalog.new(directory, pwd())

function new!(terminal::Terminal, agent::Agent, history, directory)
    selected = fresh(history, directory)
    replacement = Agent(agent.provider, agent.tools, sessionmessages(0); history=selected)
    new!(terminal, agent, history, selected, replacement)
end

function new!(terminal, agent, history, selected, rejected::History.Rejected)
    close(selected)
    agent, history, result!(terminal, rejected)
end

function new!(terminal, agent, history, selected, replacement::Agent)
    finishhistory(history)
    println(terminal.diagnostics, "New session started.")
    flush(terminal.diagnostics)
    replacement, selected, 0
end

function resume!(terminal::Terminal, agent::Agent, history, input::IO, directory::AbstractString)
    selected = SessionCatalog.choose(SessionCatalog.Picker(), directory, pwd(), input, terminal.diagnostics)
    resume!(terminal, agent, history, selected)
end

resume!(terminal::Terminal, agent::Agent, history, ::SessionCatalog.Cancelled) = (agent, history, 0)
resume!(terminal::Terminal, agent::Agent, history, rejected::History.Rejected) = (agent, history, result!(terminal, rejected))

function resume!(terminal::Terminal, agent::Agent, history, selected::History.Tree)
    restored = Agent(agent.provider, agent.tools, Dict{String, Any}[]; history=selected)
    resume!(terminal, agent, history, selected, restored)
end

function resume!(terminal::Terminal, agent::Agent, history, selected::History.Tree, rejected::History.Rejected)
    close(selected)
    agent, history, result!(terminal, rejected)
end

resume!(terminal::Terminal, agent::Agent, history, selected::History.Tree, restored::Agent) = resume!(terminal, agent, history, selected, restored, restored.fault)

function resume!(terminal::Terminal, agent::Agent, history, selected::History.Tree, restored::Agent, fault::History.Rejected)
    status = sessionfault!(terminal, fault, selected)
    close(selected)
    agent, history, status
end

function resume!(terminal::Terminal, agent::Agent, history, selected::History.Tree, restored::Agent, ::Nothing)
    close(history)
    println(terminal.diagnostics, "Resumed session.")
    flush(terminal.diagnostics)
    restored, selected, 0
end
