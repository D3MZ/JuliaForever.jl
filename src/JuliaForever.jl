module JuliaForever

using HTTP, JSON3, Unicode, Base64, Random, SHA

export Execution
export Read, Write, Edit, Bash, PowerShell, Ls, Find, Grep, CodeMode, CodeCancellation, CodeResult, cancel!, codeexecute, ToolResult, execute, Agent, OpenAI, OpenAIResponses, Usage, Completion, InvalidResponse, OpenRouterLogin, OpenRouterCallback, provider, authorize, exchange, stream, respond!, Durable, History, Sessions, Kernel, Conversation

include("instructions.jl")
include("tools.jl")
include("system.jl")
include("provider.jl")
include("kernel.jl")
include("conversation.jl")
include("durable.jl")
include("history.jl")
include("agent.jl")
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

function configured(env, login)
    selected = get(env, "JF_PROVIDER", "openai")
    required = login ? ("OPENROUTER_MODEL",) : selected in ("openai", "openai-responses") ? ("OPENAI_MODEL", "OPENAI_API_KEY") : selected == "openrouter" ? ("OPENROUTER_MODEL", "OPENROUTER_API_KEY") : ()
    missing = filter(name -> !haskey(env, name), required)
    isempty(missing) && return true
    println(stderr, "Set ", join(missing, " and "), ".")
    false
end

function (@main)(args)
    codemode = !isempty(args) && first(args) == "--codemode"
    codemode && (args = args[2:end])
    if args == ["--help"] || args == ["-h"]
        println("jf [--codemode] [prompt] | jf [--codemode] --login-openrouter [prompt] | jf [--codemode] --login-openrouter-callback [prompt]\nSet OPENAI_API_KEY and OPENAI_MODEL. Set JF_PROVIDER=openai-responses for Responses or JF_PROVIDER=openrouter and OPENROUTER_API_KEY and OPENROUTER_MODEL for OpenRouter. Code mode runs Julia with your permissions. Set JF_INSTRUCTIONS_DIR to include global instructions.")
        return 0
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
        println(stderr, "Unknown JF_PROVIDER; choose openai, openai-responses, or openrouter.")
        return 2
    end
    tools = Tool[Read(pwd()), Write(pwd()), Edit(pwd()), Bash(pwd()), Ls(pwd()), Find(pwd()), Grep(pwd())]
    Sys.iswindows() && push!(tools, PowerShell(pwd()))
    codemode && push!(tools, CodeMode(tools))
    context = Instructions.render(Instructions.load(pwd(); agentdir=get(ENV, "JF_INSTRUCTIONS_DIR", nothing)))
    messages = Dict{String, Any}[]
    isnothing(context) || push!(messages, Dict("role" => "system", "content" => context))
    agent = Agent(model, Dict{String, Tool}(name(tool) => tool for tool in tools), messages)
    terminal = Terminal(stdout, stderr, [model.key])
    if isempty(args)
        interactive = stdin isa Base.TTY
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
            status = max(status, run!(terminal, agent, line))
        end
        return status
    else
        return run!(terminal, agent, join(args, " "))
    end
end

end
