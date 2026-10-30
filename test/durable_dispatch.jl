module DurableDispatchTests

using Test, JuliaForever
import JuliaForever.Durable as D

@testset "durable record variants preserve validation" begin
    state = D.State()
    @test D.apply!(state, D.Conversation(1, nothing)) === nothing
    @test D.apply!(state, D.Entry(2, 1, "input", "a")) === nothing
    @test D.apply!(state, D.Task(3, 1, "running")) === nothing
    @test D.apply!(state, D.Document(4, 1, "old")) === nothing
    @test D.apply!(state, D.Submission(5, 1, "request", "input", "queued", nothing)) === nothing

    @test D.apply!(state, D.Conversation(0, nothing)) == D.Rejected(:invalid_id)
    @test D.apply!(state, D.Conversation(1, "changed")) == D.Rejected(:immutable)
    @test D.apply!(state, D.Entry(2, 1, "input", "changed")) == D.Rejected(:immutable)
    @test D.apply!(state, D.Task(2, 1, "bad type")) == D.Rejected(:id_in_use)
    @test D.apply!(state, D.Task(3, 9, "wrong owner")) == D.Rejected(:immutable)
    @test D.apply!(state, D.Document(4, 9, "wrong owner")) == D.Rejected(:immutable)
    @test D.apply!(state, D.Submission(5, 1, "different", "input", "queued", nothing)) == D.Rejected(:immutable)
    @test D.apply!(state, D.Submission(5, 1, "request", "write", "queued", nothing)) == D.Rejected(:immutable)
    @test D.apply!(state, D.Submission(6, 1, "request", "input", "queued", nothing)) == D.Rejected(:request_in_use)
    @test D.apply!(state, D.Document(7, 9, nothing)) == D.Rejected(:conversation_missing)
    @test !haskey(state.records, 6) && !haskey(state.records, 7)
    @test state.requests == Dict((1, "request") => 5)

    @test D.apply!(state, D.Task(3, 1, "done")) === nothing
    @test D.apply!(state, D.Document(4, 1, "new")) === nothing
    @test D.apply!(state, D.Submission(5, 1, "request", "input", "done", nothing)) === nothing
    @test D.apply!(state, D.Submission(8, 1, nothing, "input", "queued", nothing)) === nothing
    @test state.records[3].state == "done"
    @test state.records[4].value == "new"
    @test state.records[5].status == "done"
    @test state.requests == Dict((1, "request") => 5)
end

end
