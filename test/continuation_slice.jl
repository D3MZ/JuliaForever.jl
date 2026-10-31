using Test, JuliaForever
mutable struct ContinuationProvider
    replies::Vector{String}
    requests::Vector{Any}
end
function JuliaForever.complete(p::ContinuationProvider, messages, tools)
    push!(p.requests, deepcopy(messages))
    Dict{String, Any}("role" => "assistant", "content" => popfirst!(p.replies))
end

mutable struct ContinueHookProvider
    replies::Vector{Any}
    requests::Vector{Any}
end
function JuliaForever.complete(provider::ContinueHookProvider, messages, tools)
    push!(provider.requests, deepcopy(messages))
    popfirst!(provider.replies)
end
struct ContinueHookTool <: JuliaForever.Tool end
JuliaForever.name(::ContinueHookTool) = "continue_hook_tool"
JuliaForever.execute(::ContinueHookTool, args) = ToolResult("original")
