module JuliaForever

using HTTP, JSON3, Unicode, Base64, Random, SHA

export Execution
export Read, Write, Edit, Bash, PowerShell, Ls, Find, Grep, CodeMode, CodeCancellation, CodeResult, cancel!, codeexecute, ToolResult, execute, Agent, OpenAI, OpenAIResponses, Usage, Completion, OpenRouterLogin, provider, authorize, exchange, stream, respond!, Durable, History, Sessions, Kernel, Conversation

include("tools.jl")
include("provider.jl")
include("kernel.jl")
include("conversation.jl")
include("agent.jl")
include("responses.jl")
include("system.jl")
include("durable.jl")
include("history.jl")
include("sessions.jl")
include("execution.jl")
include("execution_kernel.jl")
include("logs.jl")
include("search.jl")
include("codemode.jl")
include("terminal.jl")

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
        println("jf [--codemode] [prompt] | jf [--codemode] --login-openrouter [prompt]\nSet OPENAI_API_KEY and OPENAI_MODEL. Set JF_PROVIDER=openai-responses for Responses or JF_PROVIDER=openrouter and OPENROUTER_API_KEY and OPENROUTER_MODEL for OpenRouter. Code mode runs Julia with your permissions.")
        return 0
    end
    login_requested = !isempty(args) && first(args) == "--login-openrouter"
    configured(ENV, login_requested) || return 2
    if login_requested
        login = authorize()
        println("Open this URL and authorize Julia Forever: ", login.url)
        print("Authorization code: ")
        flush(stdout)
        code = strip(readline(stdin))
        base = get(ENV, "OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1")
        result = request!(Terminal(stdout, stderr, String[])) do
            exchange(login, code; base)
        end
        result.status == 0 || return result.status
        key = result.value
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
    agent = Agent(model, tools)
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
