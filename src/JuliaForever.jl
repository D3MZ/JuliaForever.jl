module JuliaForever

using HTTP, JSON3, Unicode, Base64, Random, SHA, REPL

export Execution
export Read, Write, Edit, Bash, PowerShell, Ls, Find, Grep, CodeMode, CodeCancellation, CodeResult, cancel!, codeexecute, Image, ToolResult, execute, Agent, OpenAI, OpenAIResponses, Usage, Completion, InvalidResponse, OpenRouterLogin, OpenRouterCallback, provider, authorize, exchange, stream, respond!, Durable, History, Sessions, Kernel, Conversation

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
include("extensions.jl")
include("agent_history.jl")
include("responses.jl")
include("sessions.jl")
include("execution.jl")
include("execution_kernel.jl")
include("agent_execution.jl")
include("logs.jl")
include("search.jl")
include("codemode.jl")
include("terminal.jl")
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

function pluginfailure!(terminal::Terminal, name, exception)
    exception isa InterruptException && return failure!(terminal, exception)
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
    for name in packages
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
        result isa Extensions.Rejected && return pluginfailure!(terminal, name, result)
    end
    registry
end

function (@main)(args)
    codemode = false
    packages = String[]
    environments = String[]
    path = nothing
    reason = nothing
    inspect = false
    selected = nothing
    requested_model = nothing
    login_requested = false
    callback_requested = false
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
            if login_requested
                println(stderr, "Select only one OpenRouter login mode.")
                return 2
            end
            login_requested = true
            callback_requested = first(args) == "--login-openrouter-callback"
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
        println("jf [--provider NAME] [--model ID] [--codemode] [--history PATH] [prompt] | jf --history PATH --inspect-history | jf --history PATH --abandon REASON | jf [options] --login-openrouter [prompt] | jf [options] --login-openrouter-callback [prompt]\nProviders: openai, openai-responses, openrouter. --provider overrides JF_PROVIDER; --model overrides OPENAI_MODEL or OPENROUTER_MODEL. Set the selected provider's API key. Use --plugin PACKAGE and optional --plugin-env PATH to load a trusted native Julia plugin; both options may be repeated. Code mode runs Julia with your permissions. Set JF_INSTRUCTIONS_DIR to include global instructions.")
        return 0
    end
    if !isnothing(selected) && isnothing(providerinfo(selected))
        println(stderr, "Unknown provider; choose openai, openai-responses, or openrouter.")
        return 2
    end
    if inspect
        if isnothing(path) || !isnothing(reason) || login_requested || !isempty(args)
            println(stderr, "--inspect-history requires --history PATH and no prompt or --abandon.")
            return 2
        end
        return inspecthistory!(Terminal(stdout, stderr, String[]), path)
    end
    if !isnothing(reason)
        if isnothing(path) || login_requested || !isempty(args)
            println(stderr, "--abandon requires --history PATH and no prompt.")
            return 2
        end
        return abandonhistory!(Terminal(stdout, stderr, String[]), path, reason)
    end
    if login_requested && !isnothing(selected) && selected != "openrouter"
        println(stderr, "OpenRouter login requires --provider openrouter.")
        return 2
    end
    selected = login_requested ? "openrouter" : something(selected, get(ENV, "JF_PROVIDER", "openai"))
    info = providerinfo(selected)
    if isnothing(info)
        println(stderr, "Unknown provider; choose openai, openai-responses, or openrouter.")
        return 2
    end
    if login_requested
        configuredlogin(ENV, info, requested_model) || return 2
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
        model = OpenAI(base, modelvalue(ENV, info.model, requested_model), key)
    else
        configured(ENV, info, requested_model) || return 2
        model = provider(info, ENV, requested_model)
    end
    tools = Tool[Read(pwd()), Write(pwd()), Edit(pwd()), Bash(pwd()), Ls(pwd()), Find(pwd()), Grep(pwd())]
    Sys.iswindows() && push!(tools, PowerShell(pwd()))
    terminal = Terminal(stdout, stderr, [model.key])
    registry = plugins(terminal, tools, packages, environments)
    registry isa Integer && return registry
    Base.invokelatest(terminal!, terminal, model, registry, codemode, path, args)
end

function terminal!(terminal::Terminal, model, registry::Extensions.Registry, codemode, path, args)
    if codemode
        mode = CodeMode(Extensions.tools(Extensions.snapshot(registry)))
        result = Extensions.register!(registry, gensym(:codemode), Extensions.Plugin(; tools=(mode,)))
        result isa Extensions.Rejected && return pluginfailure!(terminal, "codemode", result)
    end
    extensions = Extensions.snapshot(registry)
    history = isnothing(path) ? nothing : open(History.SQLite, path)
    history isa History.Rejected && return result!(terminal, history)
    try
        snapshot = isnothing(history) ? nothing : History.snapshot(history)
        snapshot isa History.Rejected && return result!(terminal, snapshot)
        messages = Dict{String, Any}[]
        if isnothing(snapshot) || snapshot.revision == 0
            context = Instructions.render(Instructions.load(pwd(); agentdir=get(ENV, "JF_INSTRUCTIONS_DIR", nothing)))
            isnothing(context) || push!(messages, Dict("role" => "system", "content" => context))
        end
        agent = Agent(model, extensions, messages; history)
        agent isa History.Rejected && return result!(terminal, agent)
        isnothing(agent.fault) || return result!(terminal, agent.fault)
        if isempty(args)
            interactive = stdin isa Base.TTY
            if interactive && stderr isa Base.TTY && get(ENV, "TERM", "") ∉ ("", "dumb")
                println(stderr, "Julia Forever — Enter sends; Ctrl+J adds a line; /exit quits")
                return edit!(terminal, agent, extensions)
            end
            interactive && println(stderr, "Julia Forever — enter a message, or /exit to quit")
            status = 0
            while true
                if interactive
                    print(stderr, "> ")
                    flush(stderr)
                end
                eof(stdin) && break
                line = readline(stdin)
                line == "/exit" && break
                status = max(status, run!(terminal, agent, line, extensions))
            end
            return status
        else
            return run!(terminal, agent, join(args, " "), extensions)
        end
    finally
        isnothing(history) || close(history)
    end
end

end
