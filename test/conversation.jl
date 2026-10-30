using Test, JuliaForever, JSON3

import JuliaForever.Kernel as K
import JuliaForever.Conversation as C

function reply(text; calls=C.ToolCall[], finish="stop", done=true)
    C.ModelReply(C.Assistant(text, calls, finish, done))
end

@testset "assistant completion serialization" begin
    for done in (true, false)
        message = C.Assistant("answer", C.ToolCall[], "stop", done; metadata=Dict("note" => "kept"))
        encoded = JSON3.write(message)
        @test JSON3.read(encoded).done == done
        restored = JSON3.read(encoded, C.Assistant)
        @test restored.done == done && restored.content == "answer" && restored.metadata["note"] == "kept"
        @test isequal(restored, message)
    end
end

@testset "conversation state properties" begin
    state = C.State("properties"; automatic=false)
    @test !state.automatic && !state.cancelled
    encoded = JSON3.read(JSON3.write(state))
    @test !encoded.automatic && !encoded.cancelled
    @test encoded.steeringmode == "one-at-a-time" && encoded.followupmode == "one-at-a-time"
    all = K.step(state, C.SteeringMode(0, C.AllAtOnce())).state
    @test JSON3.read(JSON3.write(all)).steeringmode == "all"
    cancelled = K.step(state, C.Cancel(0)).state
    @test !cancelled.automatic && cancelled.cancelled
    encoded = JSON3.read(JSON3.write(cancelled))
    @test !encoded.automatic && encoded.cancelled
end

@testset "conversation transitions" begin
    state = C.State("session")
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

@testset "queued messages retain earlier revisions" begin
    initial = C.State("snapshots"; automatic=false)
    first = K.step(initial, C.Steer(0, "steer one")).state
    second = K.step(first, C.Steer(1, "steer two")).state
    third = K.step(second, C.Followup(2, "follow one")).state
    fourth = K.step(third, C.Followup(3, "follow two")).state
    branch = K.step(first, C.Followup(1, "branch")).state

    @test isempty(initial.steering) && isempty(initial.followups)
    @test first.steering == ["steer one"] && isempty(first.followups)
    @test second.steering == ["steer one", "steer two"] && isempty(second.followups)
    @test third.followups == ["follow one"]
    @test fourth.followups == ["follow one", "follow two"]
    @test branch.steering == ["steer one"] && branch.followups == ["branch"]
    push!(fourth.steering, "outside")
    empty!(fourth.followups)
    @test fourth.steering == ["steer one", "steer two"]
    @test fourth.followups == ["follow one", "follow two"]

    input = K.step(fourth, C.Input(4, "start"))
    model = K.step(input.state, C.Advance(5))
    @test [message.content for message in only(model.effects).effect.messages] == ["start", "steer one"]
    @test model.state.steering == ["steer two"]
    @test fourth.steering == ["steer one", "steer two"]
end

@testset "deferred planning and ordered tool messages" begin
    input = K.step(C.State("deferred"; automatic=false), C.Input(0, "start"))
    @test input.state.phase == C.ReadyModel && isempty(input.effects)
    queued = K.step(input.state, C.Steer(1, "steer"))
    model = K.step(queued.state, C.Advance(2))
    @test model.state.phase == C.WaitingModel
    @test [message.content for message in only(model.effects).effect.messages] == ["start", "steer"]
    calls = [C.ToolCall("a", "write", "{}"), C.ToolCall("b", "read", "{}")]
    plan = K.step(model.state, K.Observe(3, only(model.effects).id, reply(nothing; calls, finish="tool_calls")))
    first = K.step(plan.state, K.Observe(4, plan.effects[1].id, C.ToolReply("one", false)))
    @test [message.id for message in first.state.messages if message isa C.ToolMessage] == ["a"]
    @test first.state.phase == C.WaitingTools
    second = K.step(first.state, K.Observe(5, plan.effects[2].id, C.ToolReply("two", false)))
    @test [message.id for message in second.state.messages if message isa C.ToolMessage] == ["a", "b"]
    @test second.state.phase == C.ReadyModel && isempty(second.effects)
    steered = K.step(second.state, C.Steer(6, "after tools"))
    next = K.step(steered.state, C.Advance(7))
    @test last(only(next.effects).effect.messages).content == "after tools"
    answered = K.step(next.state, K.Observe(8, only(next.effects).id, reply("answer")))
    @test answered.state.phase == C.ReadyDecision && isempty(answered.effects)
    completed = K.step(answered.state, C.Advance(9))
    @test completed.state.phase == C.Complete

    input = K.step(C.State("skip"; automatic=false), C.Input(0, "go"))
    model = K.step(input.state, C.Advance(1))
    skipped = K.step(model.state, K.Observe(2, only(model.effects).id, reply(nothing; calls=[calls[1]], finish="length")))
    @test only(skipped.effects).effect isa C.SkipRequest
    observed = K.step(skipped.state, K.Observe(3, only(skipped.effects).id, C.ToolReply("truncated", true)))
    @test observed.state.phase == C.ReadyModel
    @test last(observed.state.messages).content == "Error: truncated"

    input = K.step(C.State("cancel"; automatic=false), C.Input(0, "go"))
    cancelled = K.step(input.state, C.Cancel(1))
    @test K.step(cancelled.state, C.Advance(2)).state.phase == C.Cancelled
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
