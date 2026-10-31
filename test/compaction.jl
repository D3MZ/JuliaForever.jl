using Test, JuliaForever
import JuliaForever.Conversation as CompactConversation
import JuliaForever.History as CompactHistory

mutable struct CompactProvider
    response::Any
    requests::Vector{Any}
end

function JuliaForever.complete(provider::CompactProvider, messages, tools)
    push!(provider.requests, (; messages=deepcopy(messages), tools=deepcopy(tools)))
    deepcopy(provider.response)
end

function compactmessages()
    Dict{String, Any}[
        Dict("role" => "system", "content" => "instructions"),
        Dict("role" => "user", "content" => "first"),
        Dict("role" => "assistant", "content" => "first answer"),
        Dict("role" => "user", "content" => "second"),
        Dict("role" => "assistant", "content" => nothing, "tool_calls" => [Dict("id" => "call", "type" => "function", "function" => Dict("name" => "read", "arguments" => "{}"))]),
        Dict("role" => "tool", "tool_call_id" => "call", "content" => "file contents"),
        Dict("role" => "assistant", "content" => "second answer"),
    ]
end

function compactagent(provider; history=nothing)
    Agent(provider, Dict{String, JuliaForever.Tool}(), compactmessages(); history)
end
