@testset "Pi agent lifecycle" begin
    source = ENV["PI_SOURCE"]
    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    reference = JSON3.read(read(`node $(joinpath(@__DIR__, "agent_core_reference.mjs")) $source`, String), Dict{String, Any})
    mktempdir() do dir
        calls = [call("one", "write", (; path="a.txt", content="first")), call("two", "write", (; path="b.txt", content="second"))]
        provider = AgentFixture([completion(nothing; calls, finish="tool_calls"), completion("steered one"), completion("steered two"), completion("followed")], [])
        agent = Agent(provider, [Write(dir)])
        events = []
        @test respond!(agent, "start"; tool_execution=:sequential, on_event=identity, on_agent_event=event -> begin
            if event.type == :tool_execution_start && event.tool_call_id == "one"
                JuliaForever.steer!(agent, "steer one")
                JuliaForever.steer!(agent, "steer two")
                JuliaForever.followup!(agent, "follow up")
            end
            event.type == :message_update && return
            item = Dict{String, Any}("type" => String(event.type))
            hasproperty(event, :message) && !isnothing(event.message) && (item["role"] = event.message["role"])
            hasproperty(event, :tool_call_id) && (item["id"] = event.tool_call_id)
            push!(events, item)
        end) == "followed"
        requests = [Dict("users" => [m["content"] for m in request if m["role"] == "user"], "tools" => [m["tool_call_id"] for m in request if m["role"] == "tool"]) for request in provider.requests]
        @test events == reference["events"]
        @test requests == reference["requests"]
        @test [message["role"] for message in agent.messages] == reference["roles"]
    end
end

@testset "Pi truncated tool call recovery" begin
    source = ENV["PI_SOURCE"]
    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    reference = JSON3.read(read(`node $(joinpath(@__DIR__, "agent_truncation_pi.mjs")) $source`, String))
    mktempdir() do dir
        calls = [call("one", "write", (; path="unsafe.txt", content="partial"))]
        provider = AgentFixture([completion("partial"; calls, finish="length"), completion("recovered")], [])
        agent = Agent(provider, [Write(dir)])
        @test respond!(agent, "start"; on_event=identity) == reference.output
        @test length(provider.requests) == reference.requests == 2
        @test !isfile(joinpath(dir, "unsafe.txt")) && reference.executions == 0
        toolmessage = only(message for message in provider.requests[2] if message["role"] == "tool")
        @test startswith(toolmessage["content"], "Error:") && reference.toolError
        @test occursin("output token limit", toolmessage["content"]) && reference.limitMessage
    end
end

struct QueueModeTool <: JuliaForever.Tool
    directory::String
    gate::Channel{Nothing}
    started::Channel{Nothing}
    parallel::Bool
end
JuliaForever.name(::QueueModeTool) = "write"
JuliaForever.description(::QueueModeTool) = "Write a file in a controlled tool batch"
JuliaForever.schema(::QueueModeTool) = Dict("type" => "object", "properties" => Dict("path" => Dict("type" => "string"), "content" => Dict("type" => "string")), "required" => ["path", "content"])
function JuliaForever.execute(tool::QueueModeTool, args)
    if tool.parallel
        if args.path == "a.txt"
            put!(tool.started, nothing)
            timedwait(() -> isready(tool.gate), 30) == :ok || return ToolFailure("parallel tool gate timed out")
            take!(tool.gate)
        else
            timedwait(() -> isready(tool.started), 30) == :ok || return ToolFailure("parallel tool start timed out")
            take!(tool.started)
        end
    end
    write(joinpath(tool.directory, String(args.path)), String(args.content))
    ToolResult("Successfully wrote to " * args.path)
end

function queuerequest(message)
    role = message["role"]
    role == "user" && return Dict("role" => role, "content" => message["content"])
    role == "tool" && return Dict("role" => role, "id" => message["tool_call_id"], "content" => message["content"], "is_error" => message["is_error"])
    calls = [Dict("id" => call["id"], "name" => call["function"]["name"], "arguments" => JSON3.read(call["function"]["arguments"], Dict{String, Any})) for call in get(message, "tool_calls", [])]
    Dict("role" => role, "content" => message["content"], "calls" => calls)
end

@testset "Pi queue modes and tool batch ordering" begin
    source = ENV["PI_SOURCE"]
    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    for mode in (:sequential, :parallel), recorded in (false, true)
        reference = JSON3.read(read(`node $(joinpath(@__DIR__, "queue_modes_reference.mjs")) $source $(String(mode))`, String), Dict{String, Any})
        mktempdir() do dir
            calls = [call("one", "write", (; path="a.txt", content="first")), call("two", "write", (; path="b.txt", content="second"))]
            provider = AgentFixture([completion(nothing; calls, finish="tool_calls"), completion("steered"), completion("followed")], [])
            gate = Channel{Nothing}(1)
            started = Channel{Nothing}(1)
            tool = QueueModeTool(dir, gate, started, mode == :parallel)
            path = joinpath(dir, "history.sqlite")
            history = recorded ? open(JuliaForever.History.SQLite, path) : nothing
            try
                agent = Agent(provider, [tool]; history)
                events = []
                result = respond!(agent, "start"; tool_execution=mode, on_event=identity, on_agent_event=event -> begin
                    event.type == :message_update && return
                    item = Dict{String, Any}("type" => String(event.type))
                    hasproperty(event, :message) && !isnothing(event.message) && (item["role"] = event.message["role"])
                    hasproperty(event, :tool_call_id) && (item["id"] = event.tool_call_id)
                    push!(events, item)
                    trigger = mode == :parallel ? "two" : "one"
                    if event.type == :tool_execution_end && event.tool_call_id == trigger
                        steer!(agent, "steer one"); steer!(agent, "steer two")
                        followup!(agent, "follow one"); followup!(agent, "follow two")
                        steeringmode!(agent, :all); followupmode!(agent, :all)
                        mode == :parallel && put!(gate, nothing)
                    end
                end)
                requests = [queuerequest.(request) for request in provider.requests]
                order = [(event["type"], event["id"]) for event in events if event["type"] in ("tool_execution_start", "tool_execution_end")]
                expected = mode == :parallel ? [("tool_execution_start", "one"), ("tool_execution_start", "two"), ("tool_execution_end", "two"), ("tool_execution_end", "one")] : [("tool_execution_start", "one"), ("tool_execution_end", "one"), ("tool_execution_start", "two"), ("tool_execution_end", "two")]
                @test result == "followed"
                @test order == expected
                @test events == reference["events"]
                @test requests == reference["requests"]
                @test [message["role"] for message in agent.messages] == reference["roles"]
                @test read(joinpath(dir, "a.txt"), String) == "first"
                @test read(joinpath(dir, "b.txt"), String) == "second"
                if recorded
                    reader = open(JuliaForever.History.SQLite, path)
                    try
                        restored = Agent(provider, [tool]; history=reader)
                        @test restored.fault === nothing
                        @test restored.messages == agent.messages
                        @test restored.state.steeringmode isa JuliaForever.Conversation.AllAtOnce
                        @test restored.state.followupmode isa JuliaForever.Conversation.AllAtOnce
                        @test isempty(restored.state.steering) && isempty(restored.state.followups)
                    finally
                        close(reader)
                    end
                end
            finally
                isnothing(history) || close(history)
            end
        end
    end
end
