using Test, JSON3, JuliaForever

@testset "durable replay outcomes" begin
    durable = JuliaForever.Durable
    encode(record) = JSON3.read(JSON3.write(durable.encode(record)), Dict{String, Any})
    conversation = encode(durable.Conversation(1, "ok"))
    valid = Dict{String, Any}("seq" => 1, "nextid" => 1, "writes" => Any[conversation])
    state = durable.State()
    @test durable.replay!(state, valid) === nothing
    @test state.seq == 1 && state.nextid == 1
    @test state.records[1].value == "ok"
    @test durable.replay!(state, merge(valid, Dict("seq" => 2))) == durable.Rejected(:corrupt_log)

    bad = Any[
        merge(valid, Dict("seq" => true)),
        merge(valid, Dict("seq" => 2)),
        merge(valid, Dict("nextid" => "1")),
        merge(valid, Dict("nextid" => 0)),
        merge(valid, Dict("writes" => "not an array")),
        merge(valid, Dict("writes" => Any[])),
        merge(valid, Dict("writes" => Any[Dict("type" => "unknown", "id" => 1)])),
        merge(valid, Dict("writes" => Any[encode(durable.Entry(1, 999, "input", "bad"))])),
        Dict("seq" => 1),
    ]
    for batch in bad
        @test durable.replay!(durable.State(), batch) == durable.Rejected(:corrupt_log)
    end
end
