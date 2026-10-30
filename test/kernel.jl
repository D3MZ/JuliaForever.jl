using Test, JuliaForever, JSON3

import JuliaForever.Kernel as K

struct Probe <: K.Effect
    name::String
end

struct Report <: K.Observation
    text::String
end

Base.isequal(a::Report, b::Report) = isequal(a.text, b.text)

struct EqualBox
    value::Any
end

Base.isequal(a::EqualBox, b::EqualBox) = isequal(a.value, b.value)

@testset "kernel state properties" begin
    state = K.State("properties")
    @test !state.closed && !JSON3.read(JSON3.write(state)).closed
    finished = K.step(state, K.Finish(0)).state
    @test finished.closed && JSON3.read(JSON3.write(finished)).closed
end

@testset "observation equality preserves value types" begin
    @test K.same(Int, Int)
    @test !K.same(Int, Float64)
    @test K.same(identity, identity)
    @test !K.same(+, -)
    @test !K.same("x", SubString("x", 1:1))
    @test !K.same(Any[1], Int[1])
    @test !K.same((true,), (1,))
    @test !K.same((; x=1), (; y=1))
    @test !K.same((; x=1), (; x=true))
    original = K.Return(Dict{Any, Any}("items" => Any[(flag=true,)], true => "key"))
    duplicate = K.Return(Dict{Any, Any}(true => "key", "items" => Any[(flag=true,)]))
    different_value = K.Return(Dict{Any, Any}("items" => Any[(flag=1,)], true => "key"))
    different_key = K.Return(Dict{Any, Any}("items" => Any[(flag=true,)], 1 => "key"))
    @test isequal(original, duplicate)
    @test !isequal(original, different_value)
    @test !isequal(original, different_key)
    @test !isequal(K.Fail(Any[Dict{String, Any}("value" => true)]), K.Fail(Any[Dict{String, Any}("value" => 1)]))
    @test !isequal(K.Return(EqualBox(true)), K.Return(EqualBox(1)))
    @test isequal(K.Return(Any[NaN]), K.Return(Any[NaN]))

    first = Any[]
    second = Any[]
    different = Any[]
    append!(first, (first, true))
    append!(second, (second, true))
    append!(different, (different, 1))
    @test isequal(K.Return(first), K.Return(second))
    @test !isequal(K.Return(first), K.Return(different))

    planned = K.step(K.State("strict"), K.Plan(0, "id", Probe("work")))
    observed = K.step(planned.state, K.Observe(1, "id", original))
    @test K.step(observed.state, K.Observe(1, "id", duplicate)) isa K.Duplicate
    @test K.step(observed.state, K.Observe(1, "id", different_value)).reason == :observation_conflict
end

@testset "kernel transitions" begin
    start = K.State("conversation-1")
    @test isconcretetype(typeof(start))
    @test start.id == "conversation-1"
    @test start.revision == 0
    @test isempty(start.pending)
    @test isempty(start.observations)
    @test !start.closed

    first = K.step(start, K.Plan(0, "one", K.Call("read", (path="a",))))
    @test first isa K.Applied
    @test first.state.revision == 1
    @test first.effects[1].id == "one"
    @test first.effects[1].effect.input.path == "a"
    @test length(start.pending) == 0
    @test typeof(first.state) === typeof(start)

    second = K.step(first.state, K.Plan(1, "two", Probe("native")))
    @test second isa K.Applied
    @test second.state.revision == 2
    @test [item.id for item in second.state.pending] == ["one", "two"]
    @test second.effects[1].effect isa Probe
    @test K.step(second.state, K.Finish(2)).reason == :pending
    @test K.step(second.state, K.Plan(1, "three", Probe("stale"))).reason == :revision
    @test K.step(second.state, K.Plan(2, "one", Probe("used"))).reason == :effect_in_use
    @test K.step(second.state, K.Observe(2, "missing", K.Return("no"))).reason == :effect_missing
    @test K.step(second.state, K.Observe(1, "one", K.Return("stale"))).reason == :revision

    out_of_order = K.step(second.state, K.Observe(2, "two", Report("done")))
    @test out_of_order isa K.Applied
    @test isempty(out_of_order.effects)
    @test out_of_order.state.revision == 3
    @test [item.id for item in out_of_order.state.pending] == ["one"]
    @test [item.id for item in out_of_order.state.observations] == ["two"]

    duplicate = K.step(out_of_order.state, K.Observe(2, "two", Report("done")))
    @test duplicate isa K.Duplicate
    @test duplicate.state.revision == 3
    @test length(duplicate.state.observations) == 1
    conflict = K.step(out_of_order.state, K.Observe(2, "two", Report("different")))
    @test conflict isa K.Rejected && conflict.reason == :observation_conflict
    @test K.step(out_of_order.state, K.Plan(3, "two", Probe("reused"))).reason == :effect_in_use

    observed = K.step(out_of_order.state, K.Observe(3, "one", K.Fail("not found")))
    @test observed.state.revision == 4
    @test [item.id for item in observed.state.observations] == ["two", "one"]
    @test observed.state.observations[2].observation isa K.Fail
    @test isempty(observed.state.pending)
    @test K.step(observed.state, K.Observe(4, "one", K.Return("not found"))).reason == :observation_conflict
    @test K.step(observed.state, K.Observe(3, "one", K.Fail("not found"))) isa K.Duplicate

    finished = K.step(observed.state, K.Finish(4))
    @test finished isa K.Applied
    @test finished.state.revision == 5
    @test finished.state.closed
    @test K.step(finished.state, K.Plan(5, "three", Probe("late"))).reason == :closed
    @test K.step(finished.state, K.Finish(5)).reason == :closed
    @test K.step(finished.state, K.Observe(3, "one", K.Fail("not found"))) isa K.Duplicate
end

@testset "snapshots detach mutable values" begin
    input = Dict("items" => ["first"])
    planned = K.step(K.State("x"), K.Plan(0, "id", K.Call("work", input)))
    push!(input["items"], "original mutation")
    push!(planned.effects[1].effect.input["items"], "executor mutation")
    push!(planned.state.pending[1].effect.input["items"], "reader mutation")
    empty!(planned.state.pending)
    @test planned.state.pending[1].effect.input["items"] == ["first"]

    value = Dict("items" => ["result"])
    observed = K.step(planned.state, K.Observe(1, "id", K.Return(value)))
    push!(value["items"], "original mutation")
    push!(observed.state.observations[1].observation.value["items"], "reader mutation")
    @test observed.state.observations[1].observation.value["items"] == ["result"]
    @test planned.state.pending[1].effect.input["items"] == ["first"]
    @test K.step(observed.state, K.Observe(1, "id", K.Return(Dict("items" => ["result"])))) isa K.Duplicate
end

@testset "replay is repeatable and never executes effects" begin
    mktempdir() do dir
        path = joinpath(dir, "would-be-effect.txt")
        initial = K.State("replay")
        events = K.Event[
            K.Plan(0, "write-1", K.Call("write", Dict("path" => path, "content" => ["safe"]))),
            K.Observe(1, "write-1", K.Return(Dict("result" => ["done"]))),
            K.Finish(2),
        ]
        replay = K.Replay(initial, events)
        push!(events[1].effect.input["content"], "source mutation")
        push!(replay.events[1].effect.input["content"], "reader mutation")
        empty!(events)

        first = collect(replay)
        @test length(first) == 3
        @test all(result -> result isa K.Applied, first)
        @test [result.state.revision for result in first] == [1, 2, 3]
        @test first[1].effects[1].effect.input["content"] == ["safe"]
        @test first[end].state.closed
        @test !isfile(path)
        push!(first[1].effects[1].effect.input["content"], "consumer mutation")
        push!(first[2].state.observations[1].observation.value["result"], "consumer mutation")
        second = collect(replay)
        @test second[1].effects[1].effect.input["content"] == ["safe"]
        @test second[2].state.observations[1].observation.value["result"] == ["done"]
        @test [result.state.revision for result in second] == [1, 2, 3]
        @test !isfile(path)

        bad = K.Replay(initial, (K.Plan(0, "a", Probe("ok")), K.Observe(0, "a", Report("stale")), K.Finish(1)))
        replayed = collect(bad)
        @test length(replayed) == 2
        @test replayed[end] isa K.Rejected && replayed[end].reason == :revision
        @test [result.state.revision for result in collect(bad)] == [1, 1]
        @test isempty(collect(K.Replay(initial, ())))

        duplicate = K.Replay(initial, (K.Plan(0, "id", Probe("one")), K.Observe(1, "id", Report("done")), K.Observe(1, "id", Report("done")), K.Finish(2)))
        results = collect(duplicate)
        @test results[3] isa K.Duplicate
        @test [result.state.revision for result in results] == [1, 2, 2, 3]
    end
end
