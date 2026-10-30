abstract type TerminalCommand end
struct TreeCommand <: TerminalCommand end
struct ResumeCommand <: TerminalCommand end
struct CompactCommand <: TerminalCommand end

const terminalcommands = Dict{String, TerminalCommand}("/tree" => TreeCommand(), "/resume" => ResumeCommand(), "/compact" => CompactCommand())

command!(::TreeCommand, terminal, agent, history, input, directory) = tree!(terminal, agent, history, input)
command!(::ResumeCommand, terminal, agent, history, input, directory) = resume!(terminal, agent, history, input, directory)
command!(::CompactCommand, terminal, agent, history, input, directory) = (agent, history, compactresult!(terminal, compact!(agent)))

function compactresult!(terminal, summary::AbstractString)
    println(terminal.diagnostics, "Context compacted.")
    flush(terminal.diagnostics)
    0
end

compactresult!(terminal, result) = result!(terminal, result)

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
