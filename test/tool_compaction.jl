module ToolCompactionTests

using Test, JuliaForever, JSON3, Distributed
import JuliaForever as J
import JuliaForever.History as H

mutable struct Provider
    replies::Vector{Completion}
    requests::Vector{Any}
end
function J.complete(provider::Provider, messages, tools; parameters=Dict())
    push!(provider.requests, deepcopy(messages))
    popfirst!(provider.replies)
end
function reply(text; calls=[], finish="stop", tokens=50)
    message = Dict{String, Any}("role" => "assistant", "content" => text)
    isempty(calls) || (message["tool_calls"] = calls)
    Completion(message, Usage(tokens, 0, 0, 0, 0, tokens, nothing), finish, true, nothing)
end
function setup(root, history; chars=400, secondtokens=50)
    write(joinpath(root, "target.txt"), repeat("x", chars))
    call = Dict("id" => "read-large", "type" => "function", "function" => Dict("name" => "read", "arguments" => JSON3.write((; path="target.txt"))))
    provider = Provider([reply("first answer"), reply("second answer"; tokens=secondtokens), reply(nothing; calls=[call], finish="tool_calls"), reply("done"; tokens=20)], Any[])
    agent = Agent(provider, [Read(root)]; history)
    respond!(agent, "first")
    respond!(agent, "second")
    agent, provider
end
policy(; enabled=true) = J.AutoCompaction(100, 0; enabled)

end
