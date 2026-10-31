using Test, JSON3, JuliaForever
const ResourceMCP = JuliaForever.MCP

mutable struct ResourceProvider
    requests::Vector{Any}
end

function JuliaForever.complete(provider::ResourceProvider, messages, tools)
    push!(provider.requests, deepcopy(messages))
    calls = (("list_mcp_resources", "{}"), ("read_mcp_resource", "{\"server\":\"docs\",\"uri\":\"docs://intro\"}"))
    length(provider.requests) > length(calls) && return Dict("role" => "assistant", "content" => "done")
    name, args = calls[length(provider.requests)]
    call = Dict("id" => name, "type" => "function", "function" => Dict("name" => name, "arguments" => args))
    Dict("role" => "assistant", "content" => nothing, "tool_calls" => [call])
end

resource_server(mode, marker) = `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) $(joinpath(@__DIR__, "mcp_resources_server.jl")) $mode $marker`
