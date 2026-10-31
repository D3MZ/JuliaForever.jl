using Distributed, JSON3

mutable struct AgentFixture
    replies::Vector{Completion}
    requests::Vector{Any}
end

function JuliaForever.stream(provider::AgentFixture, messages, tools; parameters=Dict(), on_event=identity)
    push!(provider.requests, deepcopy(messages))
    result = popfirst!(provider.replies)
    content = result.message["content"]
    isnothing(content) || on_event((; type=:text, text=content))
    on_event((; type=result.done ? :done : :incomplete, result))
    result
end

function JuliaForever.complete(provider::AgentFixture, messages, tools; parameters=Dict())
    push!(provider.requests, deepcopy(messages))
    popfirst!(provider.replies)
end

function completion(content; calls=[], finish="stop", done=true, usage=nothing)
    message = Dict{String, Any}("role" => "assistant", "content" => content)
    isempty(calls) || (message["tool_calls"] = calls)
    Completion(message, usage, finish, done, done ? nothing : "interrupted")
end

call(id, name, args) = Dict("id" => id, "type" => "function", "function" => Dict("name" => name, "arguments" => JSON3.write(args)))

mutable struct ConcurrentTool <: JuliaForever.Tool
    release::Channel{Nothing}
end

JuliaForever.name(::ConcurrentTool) = "ordered"
function JuliaForever.execute(tool::ConcurrentTool, args)
    if args.value == "first"
        take!(tool.release)
    end
    ToolResult(String(args.value))
end

mutable struct ChunkFixture
    replies::Vector{Completion}
end

function JuliaForever.stream(provider::ChunkFixture, messages, tools; parameters=Dict(), on_event=identity)
    result = popfirst!(provider.replies)
    if haskey(result.message, "tool_calls")
        on_event((; type=:tool_call, index=0, id="one", name="write", arguments="{\"path\":\"a"))
        on_event((; type=:tool_call, index=0, id=nothing, name=nothing, arguments=".txt\",\"content\":\"ok\"}"))
    else
        on_event((; type=:text, text="do"))
        on_event((; type=:text, text="ne"))
    end
    on_event((; type=:done, result))
    result
end

struct FailingFixture end
function JuliaForever.stream(::FailingFixture, messages, tools; parameters=Dict(), on_event=identity)
    throw(ArgumentError("provider failed"))
end

struct CustomCompletion
    message::Dict{String, Any}
    finish::String
    done::Bool
end
struct CustomStreaming
    answer::CustomCompletion
end
JuliaForever.stream(provider::CustomStreaming, messages, tools; parameters=Dict(), on_event=identity) = provider.answer
