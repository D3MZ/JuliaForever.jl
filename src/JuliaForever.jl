module JuliaForever

using HTTP, JSON3

export Read, Write, Edit, ToolResult, execute, Agent, OpenAI, respond!

include("tools.jl")
include("agent.jl")

function (@main)(args)
    if args == ["--help"] || args == ["-h"]
        println("jf [prompt]\nSet OPENAI_API_KEY and OPENAI_MODEL; optionally set OPENAI_BASE_URL.")
        return 0
    end
    provider = OpenAI(get(ENV, "OPENAI_BASE_URL", "https://api.openai.com/v1"), ENV["OPENAI_MODEL"], ENV["OPENAI_API_KEY"])
    agent = Agent(provider, [Read(pwd()), Write(pwd()), Edit(pwd())])
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
