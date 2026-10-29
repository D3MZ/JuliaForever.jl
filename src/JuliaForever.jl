module JuliaForever

using HTTP, JSON3, Unicode, Base64, Random, SHA

export Execution
export Read, Write, Edit, Bash, PowerShell, Ls, Find, Grep, CodeMode, CodeCancellation, CodeResult, cancel!, codeexecute, ToolResult, execute, Agent, OpenAI, OpenAIResponses, Usage, Completion, OpenRouterLogin, provider, authorize, exchange, stream, respond!, Durable, Sessions, Kernel, Conversation

include("tools.jl")
include("provider.jl")
include("agent.jl")
include("responses.jl")
include("system.jl")
include("durable.jl")
include("sessions.jl")
include("kernel.jl")
include("conversation.jl")
include("execution.jl")
include("execution_kernel.jl")
include("logs.jl")
include("search.jl")
include("codemode.jl")

function (@main)(args)
    codemode = !isempty(args) && first(args) == "--codemode"
    codemode && (args = args[2:end])
    if args == ["--help"] || args == ["-h"]
        println("jf [--codemode] [prompt] | jf [--codemode] --login-openrouter [prompt]\nSet OPENAI_API_KEY and OPENAI_MODEL. Set JF_PROVIDER=openai-responses for Responses or JF_PROVIDER=openrouter and OPENROUTER_API_KEY and OPENROUTER_MODEL for OpenRouter. Code mode runs Julia with your permissions.")
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
        println(stderr, "Unknown JF_PROVIDER; choose openai, openai-responses, or openrouter.")
        return 2
    end
    tools = Tool[Read(pwd()), Write(pwd()), Edit(pwd()), Bash(pwd()), Ls(pwd()), Find(pwd()), Grep(pwd())]
    Sys.iswindows() && push!(tools, PowerShell(pwd()))
    codemode && push!(tools, CodeMode(tools))
    agent = Agent(model, tools)
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
