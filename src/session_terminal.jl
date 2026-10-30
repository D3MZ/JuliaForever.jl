abstract type TerminalCommand end
struct TreeCommand <: TerminalCommand end
struct ResumeCommand <: TerminalCommand end
struct CompactCommand <: TerminalCommand end
struct NewCommand <: TerminalCommand end
struct ExitCommand <: TerminalCommand end
struct ShowName <: TerminalCommand end
struct SetName <: TerminalCommand
    name::String
end

const terminalcommands = Dict{String, TerminalCommand}("/compact" => CompactCommand(), "/tree" => TreeCommand(), "/resume" => ResumeCommand(), "/new" => NewCommand(), "/exit" => ExitCommand())
const namepattern = r"\A/name(?: +([\s\S]*))?\z"
terminalcommand(text) = terminalcommand(get(terminalcommands, text, nothing), text)
terminalcommand(command::TerminalCommand, text) = command
terminalcommand(::Nothing, text) = namecommand(match(namepattern, text))
namecommand(::Nothing) = nothing
namecommand(found::RegexMatch) = namecommand(Conversation.sessionname(something(found[1], "")))
namecommand(name::String) = isempty(name) ? ShowName() : SetName(name)

command!(::CompactCommand, terminal, agent, history, input, directory, snapshot) = (agent, history, compactresult!(terminal, compact!(agent)))

function compactresult!(terminal, summary::AbstractString)
    println(terminal.diagnostics, "Context compacted.")
    flush(terminal.diagnostics)
    0
end

compactresult!(terminal, result) = result!(terminal, result)

command!(::TreeCommand, terminal, agent, history, input, directory, snapshot) = tree!(terminal, agent, history, input, snapshot)
command!(::ResumeCommand, terminal, agent, history, input, directory, snapshot) = resume!(terminal, agent, history, input, directory)
command!(::NewCommand, terminal, agent, history, input, directory, snapshot) = new!(terminal, agent, history, directory, snapshot)
command!(::ShowName, terminal, agent, history, input, directory, snapshot) = showname!(terminal, agent, history, SessionCatalog.sessionname(history))
command!(command::SetName, terminal, agent, history, input, directory, snapshot) = setname!(terminal, agent, history, command.name, name!(agent, command.name))

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

new!(terminal::Terminal, agent::Agent, history, directory, snapshot) = newchecked!(terminal, agent, history, directory, snapshot, sourcecheck!(terminal, agent, history))
newchecked!(terminal, agent, history, directory, snapshot, blocked::Union{PendingInputs, History.Rejected}) = (agent, history, sourcestatus!(terminal, blocked))

function newchecked!(terminal, agent, history, directory, snapshot, ::Nothing)
    selected = fresh(history, directory)
    pending = Ref{Union{Nothing, History.Tree}}(selected)
    try
        replacement = attempt(() -> Agent(agent.provider, agent.tools, initial(agent, snapshot); history=selected))
        newresult!(terminal, agent, history, selected, replacement, pending)
    finally
        release!(history, pending[])
    end
end

initial(agent::Agent, snapshot::Extensions.Snapshot) = initial(snapshot)
function initial(agent::Agent, ::Nothing)
    cwd = pwd()
    files = Instructions.load(cwd; agentdir=get(ENV, "JF_INSTRUCTIONS_DIR", nothing))
    prompt = context(cwd, collect(values(agent.tools)), files)
    Dict{String, Any}[Dict("role" => "system", "content" => prompt)]
end

newresult!(terminal, agent, history, selected, rejected::History.Rejected, pending) = (agent, history, result!(terminal, rejected))
newresult!(terminal, agent, history, selected, failure::ToolFailure, pending) = resume!(terminal, agent, history, failure)
newresult!(terminal, agent, history, selected, replacement::Agent, pending) = newresult!(terminal, agent, history, selected, replacement, pending, replacement.fault)
newresult!(terminal, agent, history, selected, replacement::Agent, pending, rejected::History.Rejected) = (agent, history, sessionfault!(terminal, rejected, selected))

function newresult!(terminal, agent, history, selected, replacement::Agent, pending, ::Nothing)
    lock(agent.lock) do
        newfinal!(terminal, agent, history, selected, replacement, pending, sourcecheck!(terminal, agent, history, agent.fault))
    end
end

newfinal!(terminal, agent, history, selected, replacement, pending, blocked::Union{PendingInputs, History.Rejected}) = (agent, history, sourcestatus!(terminal, blocked))
function newfinal!(terminal, agent, history, selected, replacement, pending, ::Nothing)
    closehistory!(history)
    pending[] = nothing
    println(terminal.diagnostics, "New session started.")
    flush(terminal.diagnostics)
    replacement, selected, 0
end

function resume!(terminal::Terminal, agent::Agent, history, input::IO, directory::AbstractString)
    resumepick!(terminal, agent, history, input, directory, sourcecheck!(terminal, agent, history))
end

function sourcecheck!(terminal::Terminal, agent::Agent, history)
    lock(agent.lock) do
        sourcecheck!(terminal, agent, history, agent.fault)
    end
end

sourcecheck!(terminal::Terminal, agent::Agent, history, rejected::History.Rejected) = rejected
sourcecheck!(terminal::Terminal, agent::Agent, history, ::Nothing) = checkqueues!(terminal, agent.state, history)
sourcestatus!(terminal::Terminal, ::PendingInputs) = 1
sourcestatus!(terminal::Terminal, rejected::History.Rejected) = result!(terminal, rejected)
resumepick!(terminal::Terminal, agent::Agent, history, input, directory, blocked::Union{PendingInputs, History.Rejected}) = (agent, history, sourcestatus!(terminal, blocked))

function resumepick!(terminal::Terminal, agent::Agent, history, input, directory, ::Nothing)
    selected = attempt(() -> SessionCatalog.choose(SessionCatalog.Picker(), directory, pwd(), input, terminal.diagnostics, text -> redact(terminal, text)))
    resume!(terminal, agent, history, selected)
end

resume!(terminal::Terminal, agent::Agent, history, ::SessionCatalog.Cancelled) = (agent, history, 0)
resume!(terminal::Terminal, agent::Agent, history, rejected::History.Rejected) = (agent, history, result!(terminal, rejected))
function resume!(terminal::Terminal, agent::Agent, history, failure::ToolFailure)
    println(terminal.diagnostics, redact(terminal, failure.text))
    flush(terminal.diagnostics)
    agent, history, 1
end

function resume!(terminal::Terminal, agent::Agent, history, selected::History.Tree)
    pending = Ref{Union{Nothing, History.Tree}}(selected)
    try
        resumeactive!(terminal, agent, history, selected, pending, sourcecheck!(terminal, agent, history))
    finally
        release!(history, pending[])
    end
end

release!(history, ::Nothing) = nothing
release!(history, selected::History.Tree) = history === selected ? nothing : close(selected)
resumeactive!(terminal::Terminal, agent::Agent, history, selected::History.Tree, pending, blocked::Union{PendingInputs, History.Rejected}) = (agent, history, sourcestatus!(terminal, blocked))

function resumeactive!(terminal::Terminal, agent::Agent, history, selected::History.Tree, pending, ::Nothing)
    history === selected && return (agent, history, 0)
    restored = attempt(() -> Agent(agent.provider, agent.tools, Dict{String, Any}[]; history=selected))
    resume!(terminal, agent, history, selected, restored, pending)
end

function resume!(terminal::Terminal, agent::Agent, history, selected::History.Tree, rejected::History.Rejected, pending)
    agent, history, result!(terminal, rejected)
end

resume!(terminal::Terminal, agent::Agent, history, selected::History.Tree, failure::ToolFailure, pending) = resume!(terminal, agent, history, failure)
resume!(terminal::Terminal, agent::Agent, history, selected::History.Tree, restored::Agent, pending) = resume!(terminal, agent, history, selected, restored, restored.fault, pending)

function resume!(terminal::Terminal, agent::Agent, history, selected::History.Tree, restored::Agent, fault::History.Rejected, pending)
    status = sessionfault!(terminal, fault, selected)
    agent, history, status
end

resume!(terminal::Terminal, agent::Agent, history, selected::History.Tree, restored::Agent, ::Nothing, pending) = resumechecked!(terminal, agent, history, selected, restored, pending, checkqueues!(terminal, restored.state, selected))
resumechecked!(terminal::Terminal, agent::Agent, history, selected::History.Tree, restored::Agent, pending, ::PendingInputs) = (agent, history, 1)

function resumechecked!(terminal::Terminal, agent::Agent, history, selected::History.Tree, restored::Agent, pending, ::Nothing)
    lock(agent.lock) do
        resumefinal!(terminal, agent, history, selected, restored, pending, sourcecheck!(terminal, agent, history, agent.fault))
    end
end

resumefinal!(terminal::Terminal, agent::Agent, history, selected::History.Tree, restored::Agent, pending, blocked::Union{PendingInputs, History.Rejected}) = (agent, history, sourcestatus!(terminal, blocked))

function resumefinal!(terminal::Terminal, agent::Agent, history, selected::History.Tree, restored::Agent, pending, ::Nothing)
    result = (restored, selected, 0)
    println(terminal.diagnostics, "Resuming session.")
    flush(terminal.diagnostics)
    closehistory!(history)
    pending[] = nothing
    result
end
