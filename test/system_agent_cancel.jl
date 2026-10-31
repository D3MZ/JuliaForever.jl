using JSON3

mutable struct ShellProvider
    replies::Vector{Any}
end

JuliaForever.complete(provider::ShellProvider, messages, tools) = popfirst!(provider.replies)

function shellreply(commands)
    calls = [Dict("id" => "shell-$i", "type" => "function", "function" => Dict("name" => "bash", "arguments" => JSON3.write((; command)))) for (i, command) in enumerate(commands)]
    Dict("role" => "assistant", "content" => nothing, "tool_calls" => calls)
end
