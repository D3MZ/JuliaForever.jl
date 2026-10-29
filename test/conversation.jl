using Test, JuliaForever

import JuliaForever.Kernel as K
import JuliaForever.Conversation as C

function reply(text; calls=C.ToolCall[], finish="stop", done=true)
    C.ModelReply(C.Assistant(text, calls, finish, done))
end

@testset "conversation transitions" begin
    state = C.State("session")
    @test isconcretetype(typeof(state))
    @test state.revision == 0
    @test state.phase == C.Ready
    @test isempty(state.messages)

    started = K.step(state, C.Input(0, "start"))
    @test started isa K.Applied
    @test started.state.revision == 1
    @test started.state.phase == C.WaitingModel
    model = only(started.effects)
    @test model.effect isa C.ModelRequest
    @test only(model.effect.messages).content == "start"
    @test isempty(state.messages)
    @test typeof(started.state) === typeof(state)

    calls = [C.ToolCall("a", "write", "{\"path\":\"a\"}"), C.ToolCall("b", "read", "{\"path\":\"b\"}")]
    answer = reply(nothing; calls, finish="tool_calls")
    planned = K.step(started.state, K.Observe(1, model.id, answer))
    @test planned isa K.Applied
    @test planned.state.phase == C.WaitingTools
    @test planned.state.revision == 2
    @test [item.effect.call.id for item in planned.effects] == ["a", "b"]
    @test all(item -> item.effect isa C.ToolRequest, planned.effects)
    @test [typeof(message) for message in planned.state.messages] == [C.User, C.Assistant]

    later = K.step(planned.state, K.Observe(2, planned.effects[2].id, C.ToolReply("second", false)))
    @test later.state.revision == 3
    @test later.state.phase == C.WaitingTools
    @test isempty(later.effects)
    @test length(later.state.messages) == 2
    @test K.step(later.state, K.Observe(2, planned.effects[2].id, C.ToolReply("second", false))) isa K.Duplicate
    @test K.step(later.state, K.Observe(2, planned.effects[2].id, C.ToolReply("changed", false))).reason == :observation_conflict
    @test K.step(later.state, K.Observe(2, planned.effects[1].id, C.ToolReply("stale", false))).reason == :revision
    @test K.step(later.state, K.Observe(3, "missing", C.ToolReply("none", false))).reason == :effect_missing

    earlier = K.step(later.state, K.Observe(3, planned.effects[1].id, C.ToolReply("first", true)))
    @test earlier.state.revision == 4
    @test earlier.state.phase == C.WaitingModel
    @test [message.id for message in earlier.state.messages if message isa C.ToolMessage] == ["a", "b"]
    @test [message.content for message in earlier.state.messages if message isa C.ToolMessage] == ["Error: first", "second"]
    next = only(earlier.effects)
    @test next.effect isa C.ModelRequest
    @test [message.id for message in next.effect.messages if message isa C.ToolMessage] == ["a", "b"]

    finished = K.step(earlier.state, K.Observe(4, next.id, reply("done")))
    @test finished.state.phase == C.Complete
    @test finished.state.revision == 5
    @test last(finished.state.messages).content == "done"
    @test isempty(finished.effects)
    @test K.step(finished.state, K.Observe(1, model.id, answer)) isa K.Duplicate
    @test K.step(finished.state, C.Input(5, "another")).state.phase == C.WaitingModel
    @test K.step(started.state, C.Input(1, "overlap")).reason == :phase
    @test K.step(started.state, K.Observe(1, model.id, C.ToolReply("wrong", false))).reason == :phase
end

@testset "truncated and incomplete model replies" begin
    state = C.State("truncation")
    started = K.step(state, C.Input(0, "run"))
    call = C.ToolCall("partial", "write", "{\"path\":")
    truncated = K.step(started.state, K.Observe(1, only(started.effects).id, reply(nothing; calls=[call], finish="length")))
    @test truncated.state.phase == C.WaitingModel
    @test only(truncated.effects).effect isa C.ModelRequest
    @test only(message for message in truncated.state.messages if message isa C.ToolMessage).iserror
    @test occursin("output token limit", last(truncated.state.messages).content)
    @test all(item -> !(item.effect isa C.ToolRequest), truncated.effects)

    started = K.step(C.State("incomplete"), C.Input(0, "run"))
    partial = K.step(started.state, K.Observe(1, only(started.effects).id, reply("partial"; finish=nothing, done=false)))
    @test partial.state.phase == C.Incomplete
    @test [typeof(message) for message in partial.state.messages] == [C.User]
    @test isempty(partial.effects)
end

@testset "steering and followups" begin
    started = K.step(C.State("queued"), C.Input(0, "original"))
    steered = K.step(started.state, C.Steer(1, "steer"))
    followed = K.step(steered.state, C.Followup(2, "follow up"))
    @test followed.state.revision == 3
    @test isempty(steered.effects) && isempty(followed.effects)
    first = K.step(followed.state, K.Observe(3, only(started.effects).id, reply("first")))
    @test first.state.phase == C.WaitingModel
    @test [message.content for message in first.state.messages if message isa C.User] == ["original", "steer"]
    second = K.step(first.state, K.Observe(4, only(first.effects).id, reply("second")))
    @test second.state.phase == C.WaitingModel
    @test [message.content for message in second.state.messages if message isa C.User] == ["original", "steer", "follow up"]
    third = K.step(second.state, K.Observe(5, only(second.effects).id, reply("third")))
    @test third.state.phase == C.Complete
end

@testset "provider metadata survives transitions and replay" begin
    @test isempty(C.Assistant("text", C.ToolCall[], "stop", true).metadata)
    metadata = Dict{String, Any}(
        "response_output" => Any[Dict{String, Any}("type" => "reasoning", "encrypted_content" => "ciphertext"), Dict{String, Any}("type" => "function_call", "call_id" => "call-1", "arguments" => "{}")],
        "reasoning_content" => "summary",
    )
    assistant = C.Assistant(nothing, [C.ToolCall("call-1", "read", "{}")], "tool_calls", true; metadata)
    metadata["response_output"][1]["encrypted_content"] = "mutated source"
    @test assistant.metadata["response_output"][1]["encrypted_content"] == "ciphertext"

    initial = C.State("metadata")
    input = C.Input(0, "read")
    started = K.step(initial, input)
    observation = K.Observe(1, only(started.effects).id, C.ModelReply(assistant))
    planned = K.step(started.state, observation)
    tool_observation = K.Observe(2, only(planned.effects).id, C.ToolReply("contents", false))
    replay = K.Replay(initial, (input, observation, tool_observation))
    assistant.metadata["response_output"][1]["encrypted_content"] = "mutated event"
    next = K.step(planned.state, tool_observation)
    saved = only(message for message in next.state.messages if message isa C.Assistant)
    sent = only(message for message in only(next.effects).effect.messages if message isa C.Assistant)
    @test saved.metadata["response_output"][1]["encrypted_content"] == "ciphertext"
    @test sent.metadata["response_output"][2]["call_id"] == "call-1"
    @test sent.metadata["reasoning_content"] == "summary"
    sent.metadata["response_output"][1]["encrypted_content"] = "mutated executor"
    @test only(message for message in next.state.messages if message isa C.Assistant).metadata["response_output"][1]["encrypted_content"] == "ciphertext"
    @test only(message for message in last(collect(replay)).state.messages if message isa C.Assistant).metadata["response_output"][1]["encrypted_content"] == "ciphertext"

    left = C.Assistant("x", C.ToolCall[], "stop", true; metadata=Dict{String, Any}("value" => true))
    right = C.Assistant("x", C.ToolCall[], "stop", true; metadata=Dict{String, Any}("value" => 1))
    @test !isequal(C.ModelReply(left), C.ModelReply(right))
end

@testset "conversation replay" begin
    mktempdir() do dir
        path = joinpath(dir, "not-executed.txt")
        initial = C.State("replay")
        call = C.ToolCall("write-call", "write", path)
        input = C.Input(0, "write")
        first = K.step(initial, input)
        model_reply = K.Observe(1, only(first.effects).id, reply(nothing; calls=[call], finish="tool_calls"))
        second = K.step(first.state, model_reply)
        tool_reply = K.Observe(2, only(second.effects).id, C.ToolReply("written", false))
        third = K.step(second.state, tool_reply)
        final_reply = K.Observe(3, only(third.effects).id, reply("done"))
        events = K.Event[input, model_reply, tool_reply, final_reply]
        replay = K.Replay(initial, events)
        empty!(events)
        push!(model_reply.observation.message.calls, C.ToolCall("mutation", "extra", ""))

        first_replay = collect(replay)
        @test [result.state.phase for result in first_replay] == [C.WaitingModel, C.WaitingTools, C.WaitingModel, C.Complete]
        @test [result.state.revision for result in first_replay] == [1, 2, 3, 4]
        @test only(first_replay[2].effects).effect.call.id == "write-call"
        @test [typeof(message) for message in last(first_replay).state.messages] == [C.User, C.Assistant, C.ToolMessage, C.Assistant]
        @test !isfile(path)
        empty!(first_replay[1].effects[1].effect.messages)
        empty!(first_replay[end].state.messages)
        second_replay = collect(replay)
        @test length(second_replay[1].effects[1].effect.messages) == 1
        @test length(second_replay[end].state.messages) == 4
        @test only(second_replay[2].effects).effect.call.id == "write-call"
        @test !isfile(path)
    end
end
