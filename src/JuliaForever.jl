module JuliaForever

using HTTP, JSON3, Unicode, Base64, Random, SHA

export Read, Write, Edit, Bash, PowerShell, Ls, ToolResult, execute, Agent, OpenAI, Usage, Completion, OpenRouterLogin, provider, authorize, exchange, stream, respond!, Durable

include("tools.jl")
include("provider.jl")
include("agent.jl")
include("system.jl")
include("durable.jl")

function (@main)(args)
    if args == ["--help"] || args == ["-h"]
        println("jf [prompt] | jf --login-openrouter [prompt]\nSet OPENAI_API_KEY and OPENAI_MODEL. Set JF_PROVIDER=openrouter and OPENROUTER_API_KEY and OPENROUTER_MODEL for OpenRouter.")
        return 0
    end
    if !isempty(args) && first(args) == "--login-openrouter"
        login = authorize()
        println("Open this URL and authorize Julia Forever: ", login.url)
        print("Authorization code: ")
        flush(stdout)
        code = strip(readline(stdin))
        base = get(ENV, "OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1")
        key = exchange(login, code; base)
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
        println(stderr, "Unknown JF_PROVIDER; choose openai or openrouter.")
        return 2
    end
    agent = Agent(model, [Read(pwd()), Write(pwd()), Edit(pwd()), Bash(pwd()), Ls(pwd()), (Sys.iswindows() ? [PowerShell(pwd())] : Tool[])...])
    if isempty(args)
        println("Julia Forever — enter a message, or /exit to quit")
        for line in eachline(stdin)
            line == "/exit" && break
            println(respond!(agent, line))
        end
    else
        println(respond!(agent, join(args, " ")))
    end
    return 0
end

end
