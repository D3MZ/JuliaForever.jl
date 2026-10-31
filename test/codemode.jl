using Test, JuliaForever, HTTP, JSON3, TOML

using JuliaForever: CodeMode, CodeCancellation, cancel!, codeexecute

struct DelayedWrite <: JuliaForever.Tool
    path::String
end
JuliaForever.name(::DelayedWrite) = "delayed_write"
JuliaForever.description(::DelayedWrite) = "Write after a delay."
JuliaForever.schema(::DelayedWrite) = Dict("type" => "object")
function JuliaForever.execute(tool::DelayedWrite, args)
    write(tool.path * ".started", "started")
    sleep(1.5)
    write(tool.path, "finished")
    ToolResult("finished")
end

struct GatedCalls <: JuliaForever.Tool
    entered::Channel{Int}
    gates::Vector{Channel{Nothing}}
    finished::Channel{Int}
    tasks::Channel{Task}
end
GatedCalls(n) = GatedCalls(Channel{Int}(n), [Channel{Nothing}(1) for _ in 1:n], Channel{Int}(n), Channel{Task}(n))
JuliaForever.name(::GatedCalls) = "gated"
JuliaForever.description(::GatedCalls) = "Wait for a test gate."
JuliaForever.schema(::GatedCalls) = Dict("type" => "object")
function JuliaForever.execute(tool::GatedCalls, args)
    id = Int(args.id)
    put!(tool.tasks, current_task())
    put!(tool.entered, id)
    take!(tool.gates[id])
    put!(tool.finished, id)
    ToolResult("reply-$id")
end

struct LargeReply <: JuliaForever.Tool
    entered::Channel{Task}
    gate::Channel{Nothing}
    marker::String
end
JuliaForever.name(::LargeReply) = "large"
JuliaForever.description(::LargeReply) = "Send a large reply."
JuliaForever.schema(::LargeReply) = Dict("type" => "object")
function JuliaForever.execute(tool::LargeReply, args)
    write(tool.marker, "started")
    put!(tool.entered, current_task())
    take!(tool.gate)
    ToolResult(repeat("x", 4_000_000))
end

function arrivals(channel, count)
    values = Int[]
    for _ in 1:count
        timedwait(() -> isready(channel), 20) == :ok || break
        push!(values, take!(channel))
    end
    values
end

mutable struct CodeProvider
    messages::Vector{Any}
    replies::Vector{Any}
end
function JuliaForever.complete(provider::CodeProvider, messages, tools)
    push!(provider.messages, deepcopy(messages))
    popfirst!(provider.replies)
end
