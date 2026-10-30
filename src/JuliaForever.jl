module JuliaForever

using HTTP, JSON3, StructTypes, Unicode, Base64, Random, SHA, REPL

export Execution, ContextEstimates
export Read, Write, Edit, Bash, PowerShell, Ls, Find, Grep, CodeMode, CodeCancellation, CodeResult, CodeSuccess, CodeFailure, cancel!, codeexecute, Image, ToolResult, ToolSuccess, ToolFailure, execute, Agent, OpenAI, OpenAIResponses, Usage, Completion, Truncated, InvalidResponse, ProviderStatus, OpenRouterLogin, OpenRouterCallback, provider, authorize, exchange, stream, respond!, Durable, History, Sessions, Kernel, Conversation

include("instructions.jl")
include("tools.jl")
include("system.jl")
include("provider.jl")
include("kernel.jl")
include("conversation.jl")
include("durable.jl")
include("history.jl")
include("sqlite_history.jl")
include("agent.jl")
include("estimates.jl")
include("extensions.jl")
include("agent_history.jl")
include("responses.jl")
include("sessions.jl")
include("session_catalog.jl")
include("execution.jl")
include("execution_kernel.jl")
include("agent_execution.jl")
include("logs.jl")
include("search.jl")
include("context.jl")
include("codemode.jl")
include("terminal.jl")
include("tree_terminal.jl")
include("mcp.jl")

missingmodel(env, info, ::Nothing) = isempty(strip(get(env, info.model, ""))) ? [info.model] : String[]
missingmodel(env, info, model::AbstractString) = isempty(strip(model)) ? [info.model] : String[]

function reportmissing(missing)
    isempty(missing) && return true
    println(stderr, "Set ", join(missing, " and "), ".")
    false
end

function configured(env, info, model)
    missing = missingmodel(env, info, model)
    isempty(get(env, info.key, "")) && push!(missing, info.key)
    reportmissing(missing)
end

configuredlogin(env, info, model) = reportmissing(missingmodel(env, info, model))

abstract type Authentication end
struct APIKeyAuth <: Authentication end
abstract type OpenRouterAuth <: Authentication end
struct CodeAuth <: OpenRouterAuth end
struct CallbackAuth <: OpenRouterAuth end

haslogin(::APIKeyAuth) = false
haslogin(::OpenRouterAuth) = true
validprovider(::Nothing) = true
validprovider(name::AbstractString) = known(providerinfo(name))
known(::Nothing) = false
known(::NamedTuple) = true
compatible(::APIKeyAuth, selected) = true
compatible(::OpenRouterAuth, ::Nothing) = true
compatible(::OpenRouterAuth, selected::AbstractString) = selected == "openrouter"
providername(::APIKeyAuth, ::Nothing) = get(ENV, "JF_PROVIDER", "openai")
providername(::APIKeyAuth, selected::AbstractString) = selected
providername(::OpenRouterAuth, selected) = "openrouter"

function authorize(::CodeAuth)
    login = authorize()
    println("Open this URL and authorize Julia Forever: ", login.url)
    print("Authorization code: ")
    flush(stdout)
    login, strip(readline(stdin))
end

function authorize(::CallbackAuth)
    callback = OpenRouterCallback()
    try
        login = authorize(callback)
        println("Open this URL and authorize Julia Forever: ", login.url)
        flush(stdout)
        login, wait(callback)
    finally
        close(callback)
    end
end

function authenticated(::Nothing, base, model)
    println(stderr, "OpenRouter did not return an API key.")
    2
end

authenticated(failure::InvalidResponse, base, model) = failure!(Terminal(stdout, stderr, String[]), failure)
authenticated(failure::ProviderStatus, base, model) = failure!(Terminal(stdout, stderr, String[]), failure)
authenticated(key::AbstractString, base, model) = OpenAI(base, model, key)

function login!(login::OpenRouterLogin, ::Nothing, info, model)
    println(stderr, "OpenRouter authorization was denied or timed out.")
    2
end

function login!(login::OpenRouterLogin, code::AbstractString, info, model)
    base = get(ENV, info.base, info.url)
    result = request!(Terminal(stdout, stderr, String[])) do
        exchange(login, code; base)
    end
    result.status == 0 || return result.status
    authenticated(result.value, base, modelvalue(ENV, info.model, model))
end

function acquire(::Authentication, ::Nothing, model)
    println(stderr, "Unknown provider; choose openai, openai-responses, or openrouter.")
    2
end

function acquire(::APIKeyAuth, info::NamedTuple, model)
    configured(ENV, info, model) || return 2
    provider(info, ENV, model)
end

function acquire(auth::OpenRouterAuth, info::NamedTuple, model)
    configuredlogin(ENV, info, model) || return 2
    login, code = authorize(auth)
    login!(login, code, info, model)
end

launch(status::Integer, packages, environments, codemode, session, sessiondir, args) = status

function launch(model::Union{OpenAI, OpenAIResponses}, packages, environments, codemode, session, sessiondir, args)
    tools = Tool[Read(pwd()), Write(pwd()), Edit(pwd()), Bash(pwd()), Ls(pwd()), Find(pwd()), Grep(pwd())]
    Sys.iswindows() && push!(tools, PowerShell(pwd()))
    terminal = Terminal(stdout, stderr, [model.key])
    registry = plugins(terminal, tools, packages, environments)
    Base.invokelatest(terminal!, terminal, model, registry, codemode, session, sessiondir, args)
end

pluginfailure!(terminal::Terminal, name, exception::InterruptException) = failure!(terminal, exception)

function pluginfailure!(terminal::Terminal, name, exception)
    println(terminal.diagnostics, "[plugin] ", redact(terminal, name), ": ", redact(terminal, sprint(showerror, exception)))
    flush(terminal.diagnostics)
    2
end

function pluginfailure!(terminal::Terminal, name, rejected::Extensions.Rejected)
    println(terminal.diagnostics, "[plugin] ", redact(terminal, name), ": ", rejected.reason, " ", redact(terminal, rejected.name))
    flush(terminal.diagnostics)
    2
end

function plugins(terminal::Terminal, tools, packages, environments)
    registry = Extensions.Registry()
    Extensions.register!(registry, gensym(:builtins), Extensions.Plugin(; tools))
    if !isempty(packages)
        for environment in reverse(environments)
            insert!(LOAD_PATH, min(2, length(LOAD_PATH) + 1), abspath(expanduser(environment)))
        end
        isempty(environments) || (ENV["JULIA_LOAD_PATH"] = join(Base.load_path(), Sys.iswindows() ? ';' : ':'))
    end
    seen = Set{Symbol}()
    result = registry
    for name in packages
        result = plugin!(terminal, result, name, seen)
    end
    result
end

plugin!(terminal, status::Integer, name, seen) = status

function plugin!(terminal, registry::Extensions.Registry, name, seen)
    id = Symbol(name)
    id in seen && return pluginfailure!(terminal, name, Extensions.Rejected(:duplicate_plugin, name))
    push!(seen, id)
    result = try
        package = Base.require(Main, id)
        factory = Base.invokelatest(getproperty, package, :plugin)
        plugin = Base.invokelatest(factory)
        Base.invokelatest(Extensions.register!, registry, id, plugin)
    catch exception
        return pluginfailure!(terminal, name, exception)
    end
    registered(terminal, registry, name, result)
end

registered(terminal, registry, name, ::Bool) = registry
registered(terminal, registry, name, result::Extensions.Rejected) = pluginfailure!(terminal, name, result)

function (@main)(args)
    codemode = false
    packages = String[]
    environments = String[]
    path = nothing
    reason = nothing
    inspect = false
    selected = nothing
    requested_model = nothing
    auth = APIKeyAuth()
    session = SessionCatalog.New()
    sessiondir = SessionCatalog.directory(ENV)
    while !isempty(args)
        if first(args) == "--codemode"
            codemode = true
            args = args[2:end]
        elseif first(args) in ("--provider", "--model")
            option = first(args)
            if length(args) < 2 || isempty(strip(args[2])) || startswith(args[2], "--")
                println(stderr, option, " requires a value.")
                return 2
            end
            if option == "--provider"
                selected = args[2]
            else
                requested_model = args[2]
            end
            args = args[3:end]
        elseif first(args) in ("--login-openrouter", "--login-openrouter-callback")
            if haslogin(auth)
                println(stderr, "Select only one OpenRouter login mode.")
                return 2
            end
            auth = first(args) == "--login-openrouter" ? CodeAuth() : CallbackAuth()
            args = args[2:end]
        elseif first(args) in ("--plugin", "--plugin-env")
            option = first(args)
            if length(args) < 2 || isempty(args[2]) || startswith(args[2], "--")
                println(stderr, option, " requires a ", option == "--plugin" ? "package name" : "path", ".")
                return 2
            end
            push!(option == "--plugin" ? packages : environments, args[2])
            args = args[3:end]
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
        println("jf [--provider NAME] [--model ID] [--codemode] [--history PATH] [prompt] | jf --history PATH --inspect-history | jf --history PATH --abandon REASON | jf [options] --login-openrouter [prompt] | jf [options] --login-openrouter-callback [prompt]\nProviders: openai, openai-responses, openrouter. --provider overrides JF_PROVIDER; --model overrides OPENAI_MODEL or OPENROUTER_MODEL. Set the selected provider's API key. Use --plugin PACKAGE and optional --plugin-env PATH to load a trusted native Julia plugin; both options may be repeated. Code mode runs Julia with your permissions. Set JF_INSTRUCTIONS_DIR to include global instructions.")
        println("Sessions: --continue (-c), --resume (-r), --session PATH|ID, --session-dir DIR, --no-session. Set JF_SESSION_DIR to choose the default directory.")
        return 0
    end
    if !validprovider(selected)
        println(stderr, "Unknown provider; choose openai, openai-responses, or openrouter.")
        return 2
    end
    if inspect
        if isnothing(path) || !isnothing(reason) || haslogin(auth) || !isempty(args) || !SessionCatalog.recovery(session)
            println(stderr, "--inspect-history requires --history PATH and no prompt or --abandon.")
            return 2
        end
        return inspecthistory!(Terminal(stdout, stderr, String[]), path)
    end
    if !isnothing(reason)
        if isnothing(path) || haslogin(auth) || !isempty(args) || !SessionCatalog.recovery(session)
            println(stderr, "--abandon requires --history PATH and no prompt.")
            return 2
        end
        return abandonhistory!(Terminal(stdout, stderr, String[]), path, reason)
    end
    if !compatible(auth, selected)
        println(stderr, "OpenRouter login requires --provider openrouter.")
        return 2
    end
    info = providerinfo(providername(auth, selected))
    model = acquire(auth, info, requested_model)
    launch(model, packages, environments, codemode, session, sessiondir, args)
end

terminal!(terminal::Terminal, model, registry::Integer, codemode, session, sessiondir, args) = registry

function initial(extensions)
    cwd = pwd()
    files = Instructions.load(cwd; agentdir=get(ENV, "JF_INSTRUCTIONS_DIR", nothing))
    prompt = context(cwd, Extensions.tools(extensions), files)
    Dict{String, Any}[Dict("role" => "system", "content" => prompt)]
end

initial(extensions, ::Nothing) = initial(extensions)
initial(extensions, snapshot::History.Snapshot) = iszero(snapshot.revision) ? initial(extensions) : Dict{String, Any}[]

selection(result::ToolFailure) = SessionCatalog.Invalid(result.text)
selection(result) = result

function terminal!(terminal::Terminal, model, registry::Extensions.Registry, codemode, session, sessiondir, args)
    if codemode
        mode = CodeMode(Extensions.tools(Extensions.snapshot(registry)))
        result = Extensions.register!(registry, gensym(:codemode), Extensions.Plugin(; tools=(mode,)))
        return terminal!(terminal, model, registered(terminal, registry, "codemode", result), false, session, sessiondir, args)
    end
    extensions = Extensions.snapshot(registry)
    history = selection(attempt(() -> SessionCatalog.choose(session, sessiondir, pwd(), stdin, stderr, text -> redact(terminal, text))))
    runsession!(history, terminal, model, extensions, args)
end

runsession!(::SessionCatalog.Cancelled, terminal, model, extensions, args) = 0

function runsession!(invalid::SessionCatalog.Invalid, terminal, model, extensions, args)
    println(terminal.diagnostics, redact(terminal, invalid.message))
    2
end

function sessionfault!(terminal, fault, history)
    status = result!(terminal, fault)
    println(terminal.diagnostics, "History file: ", redact(terminal, SessionCatalog.path(history)))
    flush(terminal.diagnostics)
    status
end

sessionfault!(terminal, fault, ::Nothing) = result!(terminal, fault)

function runsession!(history, terminal, model, extensions, args)
    history isa History.Rejected && return result!(terminal, history)
    try
        snapshot = isnothing(history) ? nothing : History.snapshot(history)
        snapshot isa History.Rejected && return result!(terminal, snapshot)
        messages = initial(extensions, snapshot)
        agent = Agent(model, extensions, messages; history)
        agent isa History.Rejected && return result!(terminal, agent)
        isnothing(agent.fault) || return sessionfault!(terminal, agent.fault, history)
        if isempty(args)
            return interact!(terminal, agent, extensions, stdin, stderr)
        else
            return run!(terminal, agent, join(args, " "), extensions)
        end
    finally
        isnothing(history) || close(history)
    end
end

intro!(output, input) = nothing
intro!(output, input::Base.TTY) = println(output, "Julia Forever — enter a message, or /exit to quit")
prompt!(output, input) = nothing

function prompt!(output, input::Base.TTY)
    print(output, "> ")
    flush(output)
end

interact!(terminal, agent, extensions, input, output) = readloop!(terminal, agent, extensions, input, output)

function interact!(terminal, agent, extensions, input::Base.TTY, output::Base.TTY)
    get(ENV, "TERM", "") in ("", "dumb") && return readloop!(terminal, agent, extensions, input, output)
    println(output, "Julia Forever — Enter sends; Ctrl+J adds a line; /exit quits")
    edit!(terminal, agent, extensions)
end

function readloop!(terminal, agent, extensions, input, output)
    intro!(output, input)
    status = 0
    history = agent.history
    while true
        prompt!(output, input)
        eof(input) && break
        line = readline(input)
        line == "/exit" && break
        if line == "/tree"
            agent, history, result = tree!(terminal, agent, history, input, extensions)
            status = max(status, result)
            continue
        end
        status = max(status, run!(terminal, agent, line, extensions))
    end
    status
end

end
