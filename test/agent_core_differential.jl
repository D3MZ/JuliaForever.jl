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

@testset "Pi queue modes and tool batch ordering" begin
    source = ENV["PI_SOURCE"]
    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    reference = JSON3.read(read(`node $(joinpath(@__DIR__, "queue_modes_reference.mjs")) $source`, String), Dict{String, Any})
    mktempdir() do dir
        calls = [call("one", "write", (; path="a.txt", content="first")), call("two", "write", (; path="b.txt", content="second"))]
        provider = AgentFixture([completion(nothing; calls, finish="tool_calls"), completion("steered"), completion("followed")], [])
        agent = Agent(provider, [Write(dir)])
        respond!(agent, "start"; on_event=identity, on_agent_event=event -> begin
            if event.type == :tool_execution_start && event.tool_call_id == "one"
                steer!(agent, "steer one"); steer!(agent, "steer two")
                followup!(agent, "follow one"); followup!(agent, "follow two")
                steeringmode!(agent, :all); followupmode!(agent, :all)
            end
        end)
        requests = [Dict("users" => [m["content"] for m in request if m["role"] == "user"], "tools" => [m["tool_call_id"] for m in request if m["role"] == "tool"]) for request in provider.requests]
        @test requests == reference["requests"]
        @test read(joinpath(dir, "b.txt"), String) == "second"
    end
end
