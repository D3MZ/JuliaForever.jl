abstract type TerminalCommand end
struct TreeCommand <: TerminalCommand end
struct ResumeCommand <: TerminalCommand end

const terminalcommands = Dict{String, TerminalCommand}("/tree" => TreeCommand(), "/resume" => ResumeCommand())

command!(::TreeCommand, terminal, agent, history, input, directory, snapshot) = tree!(terminal, agent, history, input, snapshot)
command!(::ResumeCommand, terminal, agent, history, input, directory, snapshot) = resume!(terminal, agent, history, input, directory)

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
