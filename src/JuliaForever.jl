module JuliaForever

using HTTP, JSON3, Unicode, Base64, Random, SHA

export Execution
export Read, Write, Edit, Bash, PowerShell, Ls, Find, Grep, CodeMode, CodeCancellation, CodeResult, CodeSuccess, CodeFailure, cancel!, codeexecute, ToolResult, ToolSuccess, ToolFailure, execute, Agent, OpenAI, OpenAIResponses, Anthropic, Google, Usage, Completion, InvalidResponse, OpenRouterLogin, OpenRouterCallback, provider, authorize, exchange, stream, respond!, Durable, History, Sessions, Kernel, Conversation

include("instructions.jl")
include("prompts.jl")
include("tools.jl")
include("system.jl")
include("provider.jl")
include("kernel.jl")
include("conversation.jl")
include("durable.jl")
include("history.jl")
include("sqlite_history.jl")
include("agent.jl")
include("agent_history.jl")
include("responses.jl")
include("anthropic.jl")
include("google.jl")
include("sessions.jl")
include("session_catalog.jl")
include("execution.jl")
include("execution_kernel.jl")
include("agent_execution.jl")
include("logs.jl")
include("search.jl")
include("codemode.jl")
include("terminal.jl")
include("terminal_editor.jl")
include("tree_terminal.jl")
include("session_terminal.jl")
include("terminal_live.jl")
include("mcp.jl")

const credentials = Dict("openai" => ("OPENAI_MODEL", "OPENAI_API_KEY"), "openai-responses" => ("OPENAI_MODEL", "OPENAI_API_KEY"), "openrouter" => ("OPENROUTER_MODEL", "OPENROUTER_API_KEY"), "anthropic" => ("ANTHROPIC_MODEL", "ANTHROPIC_API_KEY"), "google" => ("GEMINI_MODEL", "GEMINI_API_KEY"))

function configured(env, login)
    selected = get(env, "JF_PROVIDER", "openai")
    required = login ? ("OPENROUTER_MODEL",) : get(credentials, selected, ())
    missing = filter(name -> !haskey(env, name), required)
    isempty(missing) && return true
    println(stderr, "Set ", join(missing, " and "), ".")
    false
end

function (@main)(args)
    codemode = false
    path = nothing
    reason = nothing
    inspect = false
    session = SessionCatalog.New()
    sessiondir = SessionCatalog.directory(ENV)
    sessionname = nothing
    while !isempty(args)
        if first(args) == "--codemode"
            codemode = true
            args = args[2:end]
        elseif first(args) == "--history"
            if length(args) < 2 || startswith(args[2], "--")
                println(stderr, "--history requires a path.")
                return 2
            end
            path = args[2]
            session = SessionCatalog.assign(session, SessionCatalog.Explicit(path))
            args = args[3:end]
        elseif first(args) in ("--session", "--session-dir")
            if length(args) < 2 || isempty(args[2]) || startswith(args[2], "--")
                println(stderr, first(args), " requires a value.")
                return 2
            end
            if first(args) == "--session"
                session = SessionCatalog.assign(session, SessionCatalog.Target(args[2]))
            else
                sessiondir = abspath(expanduser(args[2]))
            end
            args = args[3:end]
        elseif first(args) in ("--continue", "-c")
            session = SessionCatalog.assign(session, SessionCatalog.Recent())
            args = args[2:end]
        elseif first(args) in ("--resume", "-r")
            session = SessionCatalog.assign(session, SessionCatalog.Picker())
            args = args[2:end]
        elseif first(args) == "--no-session"
            session = SessionCatalog.assign(session, SessionCatalog.Ephemeral())
            args = args[2:end]
        elseif first(args) in ("--name", "-n")
            if length(args) < 2 || isempty(Conversation.sessionname(args[2]))
                println(stderr, "--name requires a non-empty value.")
                return 2
            end
            sessionname = Conversation.sessionname(args[2])
            args = args[3:end]
        elseif first(args) == "--abandon"
            if length(args) < 2 || isempty(args[2]) || startswith(args[2], "--")
                println(stderr, "--abandon requires a reason.")
                return 2
            end
            reason = args[2]
            args = args[3:end]
        elseif first(args) == "--inspect-history"
            inspect = true
            args = args[2:end]
        else
            break
        end
    end
    if args == ["--help"] || args == ["-h"]
        println("jf [--codemode] [--history PATH] [prompt] | jf --history PATH --inspect-history | jf --history PATH --abandon REASON | jf [--codemode] [--history PATH] --login-openrouter [prompt] | jf [--codemode] [--history PATH] --login-openrouter-callback [prompt]\nSet OPENAI_API_KEY and OPENAI_MODEL. Set JF_PROVIDER=openai-responses for Responses or JF_PROVIDER=openrouter and OPENROUTER_API_KEY and OPENROUTER_MODEL for OpenRouter; or JF_PROVIDER=anthropic and ANTHROPIC_API_KEY and ANTHROPIC_MODEL for Anthropic; or JF_PROVIDER=google and GEMINI_API_KEY and GEMINI_MODEL for Google. Code mode runs Julia with your permissions. Set JF_INSTRUCTIONS_DIR to include global instructions.")
        println("Sessions: --continue (-c), --resume (-r), --session PATH|ID, --session-dir DIR, --no-session, --name NAME (-n). Set JF_SESSION_DIR to choose the default directory.")
        return 0
    end
    if inspect
        if isnothing(path) || !isnothing(reason) || !isempty(args) || !SessionCatalog.recovery(session) || !recoveryname(sessionname)
            println(stderr, "--inspect-history requires --history PATH and no prompt or --abandon.")
            return 2
        end
        return inspecthistory!(Terminal(stdout, stderr, String[]), path)
    end
    if !isnothing(reason)
        if isnothing(path) || !isempty(args) || !SessionCatalog.recovery(session) || !recoveryname(sessionname)
            println(stderr, "--abandon requires --history PATH and no prompt.")
            return 2
        end
        return abandonhistory!(Terminal(stdout, stderr, String[]), path, reason)
    end
    callback_requested = !isempty(args) && first(args) == "--login-openrouter-callback"
    login_requested = callback_requested || (!isempty(args) && first(args) == "--login-openrouter")
    configured(ENV, login_requested) || return 2
    if login_requested
        if callback_requested
            callback = OpenRouterCallback()
            try
                login = authorize(callback)
                println("Open this URL and authorize Julia Forever: ", login.url)
                flush(stdout)
                code = wait(callback)
            finally
                close(callback)
            end
            if isnothing(code)
                println(stderr, "OpenRouter authorization was denied or timed out.")
                return 2
            end
        else
            login = authorize()
            println("Open this URL and authorize Julia Forever: ", login.url)
            print("Authorization code: ")
            flush(stdout)
            code = strip(readline(stdin))
        end
        base = get(ENV, "OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1")
        result = request!(Terminal(stdout, stderr, String[])) do
            exchange(login, code; base)
        end
        result.status == 0 || return result.status
        key = result.value
        key isa InvalidResponse && return failure!(Terminal(stdout, stderr, String[]), key)
        if isnothing(key)
            println(stderr, "OpenRouter did not return an API key.")
            return 2
        end
        model = OpenAI(base, ENV["OPENROUTER_MODEL"], key)
        args = args[2:end]
    else
        model = provider()
    end
    if isnothing(model)
        println(stderr, "Unknown JF_PROVIDER; choose openai, openai-responses, openrouter, anthropic, or google.")
        return 2
    end
    tools = Tool[Read(pwd()), Write(pwd()), Edit(pwd()), Bash(pwd()), Ls(pwd()), Find(pwd()), Grep(pwd())]
    Sys.iswindows() && push!(tools, PowerShell(pwd()))
    codemode && push!(tools, CodeMode(tools))
    terminal = Terminal(stdout, stderr, [model.key])
    history = SessionCatalog.choose(session, sessiondir, pwd(), stdin, stderr)
    runsession!(history, terminal, model, tools, args, sessiondir, sessionname)
end

recoveryname(::Nothing) = true
recoveryname(::String) = false
runsession!(::SessionCatalog.Cancelled, terminal, model, tools, args, sessiondir, sessionname) = 0

function runsession!(invalid::SessionCatalog.Invalid, terminal, model, tools, args, sessiondir, sessionname)
    println(terminal.diagnostics, invalid.message)
    2
end

function sessionfault!(terminal, fault, history)
    status = result!(terminal, fault)
    println(terminal.diagnostics, "History file: ", SessionCatalog.path(history))
    flush(terminal.diagnostics)
    status
end

function interactive!(terminal, agent, history, input::IO, sessiondir, templates)
    status = 0
    for line in terminalinput(input, terminal.diagnostics)
        line == "/exit" && break
        agent, selected, result = interactive!(terminal, agent, history[], terminalcommand(line), line, input, sessiondir, templates)
        history[] = selected
        status = max(status, result)
    end
    status
end
interactive!(terminal, agent, history, ::Nothing, line, input, sessiondir, templates) = (agent, history, run!(terminal, agent, Prompts.expand(line, templates)))
interactive!(terminal, agent, history, command::TerminalCommand, line, input, sessiondir, templates) = command!(command, terminal, agent, history, input, sessiondir)
interactive!(terminal, agent, history, input::Base.TTY, sessiondir, templates) = LiveTerminal.loop!(terminal, agent, history, input, sessiondir, templates)
finishhistory(::Nothing) = nothing
finishhistory(history::History.Store) = close(history)

runsession!(history, terminal, model, tools, args, sessiondir) = runsession!(history, terminal, model, tools, args, sessiondir, nothing)
runsession!(rejected::History.Rejected, terminal, model, tools, args, sessiondir, sessionname) = result!(terminal, rejected)

function runsession!(history, terminal, model, tools, args, sessiondir, sessionname)
    selected = Ref{Union{Nothing, History.Store}}(history)
    try
        runsession!(sessionsnapshot(history), history, terminal, model, tools, args, sessiondir, selected, sessionname)
    finally
        finishhistory(selected[])
    end
end

sessionsnapshot(::Nothing) = nothing
sessionsnapshot(history::History.Store) = History.snapshot(history)

runsession!(rejected::History.Rejected, history, terminal, model, tools, args, sessiondir, selected, sessionname) = result!(terminal, rejected)
function runsession!(snapshot, history, terminal, model, tools, args, sessiondir, selected, sessionname)
    messages = sessionmessages(snapshot)
    agent = Agent(model, Dict{String, Tool}(name(tool) => tool for tool in tools), messages; history)
    sessionagent!(agent, history, terminal, args, sessiondir, selected, sessionname)
end

sessionmessages(::Nothing) = sessionmessages(0)
sessionmessages(snapshot::History.Snapshot) = sessionmessages(snapshot.revision)
function sessionmessages(revision::Int)
    messages = Dict{String, Any}[]
    revision == 0 || return messages
    context = Instructions.render(Instructions.load(pwd(); agentdir=get(ENV, "JF_INSTRUCTIONS_DIR", nothing)))
    sessioncontext!(messages, context)
    messages
end
sessioncontext!(messages, ::Nothing) = nothing
sessioncontext!(messages, context::AbstractString) = push!(messages, Dict("role" => "system", "content" => context))

sessionagent!(rejected::History.Rejected, history, terminal, args, sessiondir, selected, sessionname) = result!(terminal, rejected)
sessionagent!(agent::Agent, history, terminal, args, sessiondir, selected, sessionname) = sessionagent!(agent.fault, agent, history, terminal, args, sessiondir, selected, sessionname)
sessionagent!(fault::History.Rejected, agent, history, terminal, args, sessiondir, selected, sessionname) = sessionfault!(terminal, fault, history)
sessionagent!(::Nothing, agent, history, terminal, args, sessiondir, selected, sessionname) = runselected!(terminal, agent, selected, args, sessiondir, startname!(agent, sessionname))
startname!(agent, ::Nothing) = nothing
startname!(agent, name::String) = name!(agent, name)
runselected!(terminal, agent, history, args, sessiondir, rejected::History.Rejected) = result!(terminal, rejected)
function runselected!(terminal, agent, history, args, sessiondir, ::Nothing)
    templates = Prompts.load(pwd())
    isempty(args) && return interactive!(terminal, agent, history, stdin, sessiondir, templates)
    run!(terminal, agent, Prompts.expand(join(args, " "), templates))
end

end
