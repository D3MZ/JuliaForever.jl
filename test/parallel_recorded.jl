module ParallelRecordedTests

using Test, JuliaForever, JSON3
const H = JuliaForever.History
const K = JuliaForever.Kernel
const C = JuliaForever.Conversation
const E = JuliaForever.Extensions

mutable struct Provider
    responses::Vector{Any}
    requests::Vector{Any}
end
function JuliaForever.complete(provider::Provider, messages, tools; parameters=Dict())
    push!(provider.requests, deepcopy(messages))
    popfirst!(provider.responses)
end

struct Ordered <: JuliaForever.Tool
    release::Channel{Nothing}
    started::Channel{String}
end
JuliaForever.name(::Ordered) = "ordered"
JuliaForever.description(::Ordered) = "test concurrent tools"
JuliaForever.schema(::Ordered) = Dict("type" => "object")
function JuliaForever.execute(tool::Ordered, args)
    value = String(args.value)
    put!(tool.started, value)
    value == "one" && take!(tool.release)
    ToolResult(value)
end

call(id) = Dict("id" => id, "type" => "function", "function" => Dict("name" => "ordered", "arguments" => JSON3.write((; value=id))))
provider() = Provider(Any[Dict("role" => "assistant", "content" => nothing, "tool_calls" => [call("one"), call("two")]), Dict("role" => "assistant", "content" => "done")], Any[])
function addtrace!(trace, mutex, text)
    lock(mutex) do
        push!(trace, text)
    end
end

@testset "parallel tool calls preserve Pi ordering and durable observations" begin
    reference = ["start:one", "before:one", "start:two", "before:two", "end:two", "end:one", "message:one", "message:two"]
    if haskey(ENV, "PI_SOURCE")
        source = ENV["PI_SOURCE"]
        @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
        reference = JSON3.read(read(`node $(joinpath(@__DIR__, "parallel_recorded_reference.mjs")) $source`, String), Vector{String})
    end
    for mode in (:direct, :sqlite, :continue)
        @testset "$mode" begin
            mktempdir() do dir
                release = Channel{Nothing}(1)
                started = Channel{String}(2)
                second = Channel{Nothing}(1)
                trace = String[]
                mutex = ReentrantLock()
                tool = Ordered(release, started)
                historypath = joinpath(dir, "history.sqlite")
                history = mode == :direct ? nothing : open(H.SQLite, historypath)
                p = provider()
                registry = E.Registry()
                E.register!(registry, :parallel, E.Plugin(; hooks=(:tool_call => (event -> (addtrace!(trace, mutex, "before:" * event.tool_call_id); nothing)),)))
                listener = E.listen(E.snapshot(registry); on_event=event -> begin
                    event.type == :tool_execution_start && addtrace!(trace, mutex, "start:" * event.tool_call_id)
                    if event.type == :tool_execution_end
                        addtrace!(trace, mutex, "end:" * event.tool_call_id)
                        event.tool_call_id == "two" && put!(second, nothing)
                    end
                    event.type == :message_end && event.message["role"] == "tool" && addtrace!(trace, mutex, "message:" * event.message["tool_call_id"])
                end)
                initial = mode == :continue ? [Dict{String, Any}("role" => "user", "content" => "start")] : Dict{String, Any}[]
                agent = Agent(p, Dict{String, JuliaForever.Tool}("ordered" => tool), initial; history)
                task = @async mode == :continue ? continue!(agent; on_agent_event=listener) : respond!(agent, "start"; on_agent_event=listener)
                try
                    timedwait(() -> isready(second) || istaskdone(task), 15)
                    overlapping = isready(second)
                    @test overlapping
                    if overlapping && history !== nothing
                        persisted = timedwait(() -> lock(agent.lock) do
                            any(event -> event isa K.Observe && event.observation isa C.ToolReply && event.observation.result.text == "two", getfield(agent, :events))
                        end, 5) == :ok
                        @test persisted
                        if persisted
                            reader = open(H.SQLite, historypath)
                            try
                                restored = Agent(provider(), [tool]; history=reader)
                                @test restored.fault == H.Rejected(:uncertain_effect)
                                @test any(item -> item.observation isa C.ToolReply && item.observation.result.text == "two", restored.state.kernel.observations)
                            finally
                                close(reader)
                            end
                        end
                    end
                    put!(release, nothing)
                    result = fetch(task)
                    @test result == "done"
                    if result == "done"
                        @test trace == reference
                        @test [m["tool_call_id"] for m in p.requests[2] if m["role"] == "tool"] == ["one", "two"]
                        if history !== nothing
                            restored = Agent(provider(), [tool]; history)
                            @test [m.id for m in restored.state.messages if m isa C.ToolMessage] == ["one", "two"]
                        end
                    end
                finally
                    isready(release) || put!(release, nothing)
                    wait(task)
                    history === nothing || close(history)
                end
            end
        end
    end
end

struct Deferred <: JuliaForever.Tool
    id::String
end
JuliaForever.name(tool::Deferred) = tool.id

struct Discovery <: JuliaForever.Tool
    release::Channel{Nothing}
end
JuliaForever.name(::Discovery) = "ordered"
function JuliaForever.execute(tool::Discovery, args)
    value = String(args.value)
    value == "one" && take!(tool.release)
    JuliaForever.ToolLoaded(value, [value == "one" ? "repos" : "issues"])
end

struct Racing <: JuliaForever.Tool
    started::Channel{String}
    first::Channel{Nothing}
    release::Channel{Nothing}
end
JuliaForever.name(::Racing) = "ordered"
function JuliaForever.execute(tool::Racing, args)
    value = String(args.value)
    if value == "one"
        put!(tool.started, value)
        put!(tool.first, nothing)
        take!(tool.release)
    else
        take!(tool.first)
        put!(tool.started, value)
    end
    ToolResult(value)
end

end
