abstract type TerminalCommand end
struct TreeCommand <: TerminalCommand end
struct ResumeCommand <: TerminalCommand end

const terminalcommands = Dict{String, TerminalCommand}("/tree" => TreeCommand(), "/resume" => ResumeCommand())

command!(::TreeCommand, terminal, agent, history, input, directory) = tree!(terminal, agent, history, input)
command!(::ResumeCommand, terminal, agent, history, input, directory) = resume!(terminal, agent, history, input, directory)

function resume!(terminal::Terminal, agent::Agent, history, input::IO, directory::AbstractString)
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
        restored = attempt(() -> Agent(agent.provider, agent.tools, Dict{String, Any}[]; history=selected))
        resume!(terminal, agent, history, selected, restored, pending)
    finally
        release!(pending[])
    end
end

release!(::Nothing) = nothing
release!(history::History.Tree) = close(history)

function resume!(terminal::Terminal, agent::Agent, history, selected::History.Tree, rejected::History.Rejected, pending)
    agent, history, result!(terminal, rejected)
end

resume!(terminal::Terminal, agent::Agent, history, selected::History.Tree, failure::ToolFailure, pending) = resume!(terminal, agent, history, failure)
resume!(terminal::Terminal, agent::Agent, history, selected::History.Tree, restored::Agent, pending) = resume!(terminal, agent, history, selected, restored, restored.fault, pending)

function resume!(terminal::Terminal, agent::Agent, history, selected::History.Tree, restored::Agent, fault::History.Rejected, pending)
    status = sessionfault!(terminal, fault, selected)
    agent, history, status
end

function resume!(terminal::Terminal, agent::Agent, history, selected::History.Tree, restored::Agent, ::Nothing, pending)
    result = (restored, selected, 0)
    println(terminal.diagnostics, "Resuming session.")
    flush(terminal.diagnostics)
    close(history)
    pending[] = nothing
    result
end
