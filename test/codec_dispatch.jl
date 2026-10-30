using Test, JuliaForever

@testset "history codec boundaries" begin
    H = JuliaForever.History
    C = JuliaForever.Conversation
    K = JuliaForever.Kernel
    invalid = H.Rejected(:invalid_record)
    unsupported = H.Rejected(:unsupported_value)

    initial = H.encode_initial(C.State("codec"; automatic=false, messages=C.Message[C.User("hello")]))
    @test H.encode_initial(H.decode_initial(initial)) == initial
    seed = C.State("not-ready")
    waiting = C.State(seed.kernel, 0, seed.messages, C.WaitingModel, seed.order, seed.calls, seed.steering, seed.followups, seed.mode, seed.cancellation, seed.flushed)
    @test H.encode_initial(waiting) == unsupported
    @test H.decode_initial(nothing) == invalid
    @test H.decode_initial(merge(initial, Dict("automatic" => 1))) == invalid
    @test H.decode_initial(merge(initial, Dict("messages" => [H.pack(K.Call("not a message", 1))]))) == invalid
    @test H.decode_initial(Dict("format" => "other")) == invalid

    event = K.Plan(0, "id", K.Call("tool", Dict("x" => Any[1, "two"])))
    encoded = H.encode(event)
    @test H.encode(H.decode_event(encoded)) == encoded
    @test H.decode_event(nothing) == invalid
    @test H.decode_event(Dict("format" => "JuliaForever.AgentEvent/1", "event" => H.pack(C.User("not an event")))) == invalid
    @test H.decode_event(Dict("format" => "JuliaForever.AgentEvent/1", "event" => Dict("kind" => "unknown", "fields" => []))) == invalid

    values = Dict{String, Any}("nested" => Any[Dict("key" => [1, 2]), nothing, true])
    @test isequal(H.unvalue(H.packvalue(values)), values)
    @test H.packvalue(Any[1, (unsupported=true,), 2]) == unsupported
    @test H.packvalue(Tuple{Int}[]) == unsupported
    @test H.packvalue(Dict{String, Tuple{Int}}()) == unsupported
    shared = Any[1, 2]
    @test H.unvalue(H.packvalue(Any[shared, shared])) == Any[Any[1, 2], Any[1, 2]]
    seen = IdDict()
    @test H.packvalue(Any[(unsupported=true,)], seen) == unsupported
    @test isempty(seen)
    @test H.unvalue(Dict("kind" => "vector", "type" => "int", "items" => Any[1, "wrong"])) == invalid
    @test H.unvalue(Dict("kind" => "dict", "type" => "int", "items" => Dict("x" => "wrong"))) == invalid
    @test H.unvalue(Dict("kind" => "dict", "type" => "int", "items" => Dict(1 => 1))) == invalid
    @test H.unvalue(Dict("kind" => "dict", "type" => "int", "items" => Dict(String(UInt8[0xff]) => 1))) == invalid
    @test H.unpackall([H.pack(C.User("yes"))], C.Message) == C.Message[C.User("yes")]
    @test H.unpackall([H.pack(K.Call("not a message", 1))], C.Message) == invalid
    @test H.unpackall(nothing, C.Message) == invalid
    cycle = Any[]
    push!(cycle, cycle)
    @test H.packvalue(cycle) == unsupported
end
