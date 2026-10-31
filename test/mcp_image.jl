using Test, JuliaForever, HTTP, JSON3, Base64

mutable struct MCPImageProvider
    requests::Vector{Any}
end

function JuliaForever.complete(provider::MCPImageProvider, messages, tools)
    push!(provider.requests, deepcopy(messages))
    if length(provider.requests) == 1
        call = Dict("id" => "mcp-image", "type" => "function", "function" => Dict("name" => "mcp_image_mixed", "arguments" => "{}"))
        return Dict("role" => "assistant", "content" => nothing, "tool_calls" => [call])
    end
    Dict("role" => "assistant", "content" => "done")
end
