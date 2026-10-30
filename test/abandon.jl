module AbandonTests

using Test, JuliaForever
import JuliaForever.History as H
import JuliaForever.Kernel as K
import JuliaForever.Conversation as C

mutable struct StrictProvider
    requests::Vector{Any}
end

function JuliaForever.complete(provider::StrictProvider, messages, tools)
    push!(provider.requests, deepcopy(messages))
    assistant = only(message for message in messages if message["role"] == "assistant")
    expected = [call["id"] for call in assistant["tool_calls"]]
    actual = [message["tool_call_id"] for message in messages if message["role"] == "tool"]
    @test actual == expected
    @test [message["role"] for message in messages] == ["user", "assistant", "tool", "tool", "tool", "user"]
    Dict{String, Any}("role" => "assistant", "content" => "done")
end

@testset "abandonment preserves ordered tool replies and resumes a strict provider" begin
    provider = StrictProvider([])
    history = H.Memory()
    agent = Agent(provider, []; history)
    @test first(JuliaForever.transition!(revision -> C.Input(revision, "start"), agent)) isa K.Applied
    plan = first(JuliaForever.transition!(revision -> C.Advance(revision), agent))
    calls = [C.ToolCall(string(i), "write", "{}") for i in 1:3]
    answer = C.ModelReply(C.Assistant(nothing, calls, "tool_calls", true))
    planned = first(JuliaForever.transition!(revision -> K.Observe(revision, only(plan.effects).id, answer), agent))
    @test first(JuliaForever.transition!(revision -> K.Observe(revision, planned.effects[2].id, C.ToolReply("observed", false)), agent)) isa K.Applied
    old = K.step(agent.state, C.Interrupt(agent.state.revision, "old format"))
    @test length(old.state.messages) == 2
    restored = Agent(provider, []; history)
    @test restored.fault == H.Rejected(:uncertain_effect)
    @test JuliaForever.abandon!(restored, "checked") isa K.Applied
    tools = filter(message -> message["role"] == "tool", restored.messages)
    @test [message["tool_call_id"] for message in tools] == ["1", "2", "3"]
    @test [message["content"] for message in tools] == ["Error: Tool outcome unknown; abandoned: checked", "observed", "Error: Tool outcome unknown; abandoned: checked"]
    again = Agent(provider, []; history)
    @test again.messages == restored.messages
    @test K.same(last(collect(K.Replay(again.initial, again.events))).state.messages, again.state.messages)
    @test isempty(provider.requests)
    @test respond!(again, "continue") == "done"
    @test length(provider.requests) == 1
end

@testset "unrecoverable history faults are retained" begin
    history = H.Memory()
    agent = Agent(nothing, []; history)
    agent.fault = H.Rejected(:revision)
    before = H.snapshot(history).revision
    @test JuliaForever.abandon!(agent, "checked") == H.Rejected(:revision)
    @test H.snapshot(history).revision == before
end

end
