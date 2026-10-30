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

@testset "parallel preflight respects cancellation and stale history" begin
    for mode in (:cancel, :stale)
        history = H.Memory()
        release = Channel{Nothing}(1)
        put!(release, nothing)
        started = Channel{String}(2)
        p = provider()
        agent = Agent(p, [Ordered(release, started)]; history)
        result = respond!(agent, "start"; on_agent_event=event -> begin
            if event.type == :tool_execution_start && event.tool_call_id == "one"
                if mode == :cancel
                    cancel!(agent)
                else
                    revision = H.snapshot(history).revision
                    H.append!(history, revision, Any["other writer"])
                    steer!(agent, "must fail")
                end
            end
        end)
        @test result == (mode == :cancel ? :cancelled : H.Rejected(:revision))
        @test !isready(started)
        @test length(p.requests) == 1
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

@testset "parallel discovery follows transcript order during replay" begin
    history = H.Memory()
    release = Channel{Nothing}(1)
    second = Channel{Nothing}(1)
    tools = ToolSet([Discovery(release)], [Deferred("repos"), Deferred("issues")])
    agent = Agent(provider(), tools; history)
    turn = @async respond!(agent, "start"; on_agent_event=event -> event.type == :tool_execution_end && event.tool_call_id == "two" && put!(second, nothing))
    ready = timedwait(() -> isready(second) || istaskdone(turn), 15) == :ok && isready(second)
    @test ready
    if ready
        persisted = timedwait(() -> lock(agent.lock) do
            any(event -> event isa K.Observe && event.observation isa C.ToolReply && event.observation.result.text == "two", getfield(agent, :events))
        end, 5) == :ok
        @test persisted
        if persisted
            @test !haskey(agent.tools, "issues")
            partial = Agent(provider(), tools; history)
            @test partial.fault == H.Rejected(:uncertain_effect)
            @test !haskey(partial.tools, "issues")
            copy = H.Memory()
            for (index, batch) in enumerate(H.snapshot(history).batches)
                H.append!(copy, index - 1, batch)
            end
            abandoned = Agent(provider(), tools; history=copy)
            @test abandon!(abandoned, "inspected") isa K.Applied
            @test collect(keys(abandoned.tools)) == ["ordered", "tool_search", "issues"]
            @test collect(keys(Agent(provider(), tools; history=copy).tools)) == ["ordered", "tool_search", "issues"]
        end
    end
    put!(release, nothing)
    @test fetch(turn) == "done"
    @test collect(keys(agent.tools)) == ["ordered", "tool_search", "repos", "issues"]
    restored = Agent(provider(), tools; history)
    @test collect(keys(restored.tools)) == ["ordered", "tool_search", "repos", "issues"]
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

@testset "parallel cancellation and history failures join running calls" begin
    for mode in (:cancel, :stale)
        history = H.Memory()
        started = Channel{String}(2)
        release = Channel{Nothing}(1)
        tool = Racing(started, Channel{Nothing}(1), release)
        p = provider()
        agent = Agent(p, [tool]; history)
        turn = @async respond!(agent, "start"; on_agent_event=event -> begin
            if event.type == :tool_execution_end && event.tool_call_id == "two"
                if mode == :cancel
                    cancel!(agent)
                else
                    revision = H.snapshot(history).revision
                    H.append!(history, revision, Any["other writer"])
                    steer!(agent, "must fail")
                end
                put!(release, nothing)
            end
        end)
        finished = timedwait(() -> istaskdone(turn), 15) == :ok
        @test finished
        finished || put!(release, nothing)
        result = fetch(turn)
        starts = String[]
        while isready(started)
            push!(starts, take!(started))
        end
        @test result == (mode == :cancel ? :cancelled : H.Rejected(:revision))
        @test sort(starts) == ["one", "two"]
        @test length(p.requests) == 1
        if mode == :stale
            @test respond!(agent, "again") == H.Rejected(:revision)
        else
            restored = Agent(provider(), [tool]; history)
            @test isempty(restored.state.kernel.pending)
            @test [m.id for m in restored.state.messages if m isa C.ToolMessage] == ["one", "two"]
        end
    end
end

@testset "observer failure preserves finished parallel results" begin
    for recorded in (false, true), kind in (:message_start, :message_end)
        history = recorded ? H.Memory() : nothing
        release = Channel{Nothing}(1)
        put!(release, nothing)
        agent = Agent(provider(), [Ordered(release, Channel{String}(2))]; history)
        @test_throws ErrorException respond!(agent, "start"; on_agent_event=event -> begin
            event.type == kind && event.message["role"] == "tool" && event.message["tool_call_id"] == "one" && error("synthetic observer failure")
        end)
        @test [message["tool_call_id"] for message in agent.messages if message["role"] == "tool"] == ["one", "two"]
        @test [message.id for message in agent.state.messages if message isa C.ToolMessage] == ["one", "two"]
        if history !== nothing
            restored = Agent(provider(), []; history)
            @test [message.id for message in restored.state.messages if message isa C.ToolMessage] == ["one", "two"]
        end
    end
end

@testset "parallel SQLite recovery after process death" begin
    if Sys.isunix()
        mktempdir() do dir
            path = joinpath(dir, "history.sqlite")
            ready = joinpath(dir, "ready")
            started = joinpath(dir, "started")
            script = raw"""
                using JuliaForever, JSON3
                import JuliaForever.History as H
                import JuliaForever.Kernel as K
                import JuliaForever.Conversation as C
                struct Provider end
                function JuliaForever.complete(::Provider, messages, tools)
                    calls = [Dict("id" => value, "type" => "function", "function" => Dict("name" => "crash-test", "arguments" => JSON3.write((; value)))) for value in ("one", "two")]
                    Dict("role" => "assistant", "content" => nothing, "tool_calls" => calls)
                end
                struct CrashTool <: JuliaForever.Tool
                    release::Channel{Nothing}
                    marker::String
                end
                JuliaForever.name(::CrashTool) = "crash-test"
                function JuliaForever.execute(tool::CrashTool, args)
                    if args.value == "one"
                        write(tool.marker, "started")
                        take!(tool.release)
                    end
                    ToolResult(String(args.value))
                end
                history = open(H.SQLite, ARGS[1])
                agent = Agent(Provider(), [CrashTool(Channel{Nothing}(1), ARGS[3])]; history)
                @async begin
                    while true
                        observed = lock(agent.lock) do
                            any(event -> event isa K.Observe && event.observation isa C.ToolReply && event.observation.result.text == "two", getfield(agent, :events))
                        end
                        observed && isfile(ARGS[3]) && break
                        sleep(0.01)
                    end
                    write(ARGS[2], "ready")
                end
                respond!(agent, "start")
            """
            project = dirname(@__DIR__)
            output = open(joinpath(dir, "child.log"), "w")
            process = run(pipeline(ignorestatus(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project -e $script $path $ready $started`), stdout=output, stderr=output); wait=false)
            try
                reached = timedwait(() -> isfile(ready) || process_exited(process), 90) == :ok && isfile(ready)
                @test reached
                @test isfile(started)
                process_exited(process) || kill(process, 9)
                wait(process)
                if reached
                    history = open(H.SQLite, path)
                    try
                        p = provider()
                        restored = Agent(p, []; history)
                        @test restored.fault == H.Rejected(:uncertain_effect)
                        @test length(restored.state.kernel.pending) == 1
                        @test any(item -> item.observation isa C.ToolReply && item.observation.result.text == "two", restored.state.kernel.observations)
                        @test respond!(restored, "again") == H.Rejected(:uncertain_effect)
                        @test isempty(p.requests)
                    finally
                        close(history)
                    end
                end
            finally
                process_exited(process) || kill(process, 9)
                wait(process)
                close(output)
            end
        end
    end
end

end
