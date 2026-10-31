using Test, JuliaForever, JSON3

const MCP = JuliaForever.MCP

mutable struct MCPProvider
    requests::Vector{Any}
end

function JuliaForever.complete(provider::MCPProvider, messages, tools)
    push!(provider.requests, deepcopy(messages))
    if length(provider.requests) == 1
        call = Dict("id" => "mcp-call", "type" => "function", "function" => Dict("name" => "mcp_alpha", "arguments" => "{\"value\":42}"))
        return Dict("role" => "assistant", "content" => nothing, "tool_calls" => [call])
    end
    Dict("role" => "assistant", "content" => "done")
end

function mcpserver(mode, marker)
    `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) $(joinpath(@__DIR__, "mcp_server.jl")) $mode $marker`
end
