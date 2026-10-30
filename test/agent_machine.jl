using Test, JuliaForever

import JuliaForever.Kernel as K
import JuliaForever.Conversation as C

@testset "agent is driven by replayable conversation transitions" begin
    mktempdir() do dir
        calls = [call("write-1", "write", (; path="a.txt", content="safe"))]
        provider = AgentFixture([completion(nothing; calls, finish="tool_calls"), completion("done")], [])
        agent = Agent(provider, [Write(dir)])
        @test respond!(agent, "start"; on_event=identity) == "done"
        @test agent.state.phase == C.Complete
        @test any(event -> event isa C.Input, agent.events)
        @test any(event -> event isa K.Observe && event.observation isa C.ModelReply, agent.events)
        @test any(event -> event isa K.Observe && event.observation isa C.ToolReply, agent.events)
        @test [typeof(message) for message in agent.state.messages] == [C.User, C.Assistant, C.ToolMessage, C.Assistant]
        @test read(joinpath(dir, "a.txt"), String) == "safe"
        requests = length(provider.requests)
        rm(joinpath(dir, "a.txt"))
        replay = collect(K.Replay(agent.initial, agent.events))
        @test last(replay).state.phase == C.Complete
        @test [typeof(message) for message in last(replay).state.messages] == [C.User, C.Assistant, C.ToolMessage, C.Assistant]
        @test last(last(replay).state.messages).content == "done"
        @test !isfile(joinpath(dir, "a.txt"))
        @test length(provider.requests) == requests
    end
end

mutable struct FailsOnce
    calls::Int
end

function JuliaForever.complete(provider::FailsOnce, messages, tools)
    provider.calls += 1
    provider.calls == 1 && error("synthetic failure")
    completion("recovered")
end

@testset "failed execution leaves a replayable state that can resume" begin
    provider = FailsOnce(0)
    agent = Agent(provider, [])
    @test_throws ErrorException respond!(agent, "first")
    @test agent.state.phase == C.Incomplete
    @test respond!(agent, "retry") == "recovered"
    @test last(collect(K.Replay(agent.initial, agent.events))).state.phase == C.Complete

    calls = [call("one", "write", (; path="a.txt", content="text"))]
    provider = AgentFixture([completion(nothing; calls, finish="tool_calls"), completion("recovered")], [])
    agent = Agent(provider, [])
    @test_throws ErrorException respond!(agent, "first"; on_event=identity, on_agent_event=event -> event.type == :tool_execution_start && error("callback failed"))
    @test agent.state.phase == C.Incomplete
    @test respond!(agent, "retry") == "recovered"
    @test last(collect(K.Replay(agent.initial, agent.events))).state.phase == C.Complete
end

@testset "message callbacks can steer the next planned model request" begin
    provider = AgentFixture([completion("first"), completion("second")], [])
    agent = Agent(provider, [])
    @test respond!(agent, "start"; on_event=identity, on_agent_event=event -> begin
        if event.type == :message_end && event.message["role"] == "user" && event.message["content"] == "start"
            JuliaForever.steer!(agent, "before model")
        elseif event.type == :message_end && event.message["role"] == "assistant" && event.message["content"] == "first"
            JuliaForever.followup!(agent, "after answer")
        end
    end) == "second"
    @test [message["content"] for message in provider.requests[1] if message["role"] == "user"] == ["start", "before model"]
    @test [message["content"] for message in provider.requests[2] if message["role"] == "user"] == ["start", "before model", "after answer"]
    @test last(collect(K.Replay(agent.initial, agent.events))).state.phase == C.Complete
end

@testset "sequential tool message callbacks affect the next model request" begin
    mktempdir() do dir
        calls = [call("one", "write", (; path="a.txt", content="first")), call("two", "write", (; path="b.txt", content="second"))]
        provider = AgentFixture([completion(nothing; calls, finish="tool_calls"), completion("done")], [])
        agent = Agent(provider, [Write(dir)])
        result = respond!(agent, "start"; on_event=identity, on_agent_event=event -> begin
            if event.type == :message_end && event.message["role"] == "tool" && event.message["tool_call_id"] == "two"
                JuliaForever.steer!(agent, "after tools")
            end
        end)
        @test result == "done"
        @test [message["content"] for message in provider.requests[2] if message["role"] == "user"] == ["start", "after tools"]
        @test [message.id for message in agent.state.messages if message isa C.ToolMessage] == ["one", "two"]
        @test last(collect(K.Replay(agent.initial, agent.events))).state.phase == C.Complete
    end
end
