using Test, JuliaForever, JSON3
import JuliaForever.History as CompactionHistory

mutable struct CompactionProvider
    requests::Vector{Any}
end

function JuliaForever.complete(provider::CompactionProvider, messages, tools)
    push!(provider.requests, deepcopy(messages))
    Dict{String, Any}("role" => "assistant", "content" => "next answer")
end

@testset "manual compaction projects Pi's checkpoint" begin
    reference = JSON3.read(read(`node $(joinpath(@__DIR__, "compaction_pi.mjs")) $(ENV["PI_SOURCE"])`, String), Dict{String, Any})
    initial = Dict{String, Any}[
        Dict("role" => "system", "content" => "instructions"),
        Dict("role" => "user", "content" => "old request"),
        Dict("role" => "assistant", "content" => "old answer"),
        Dict("role" => "user", "content" => "recent request"),
        Dict("role" => "assistant", "content" => "recent answer"),
    ]
    mktempdir() do dir
        history = open(CompactionHistory.SQLite, joinpath(dir, "history.sqlite"))
        provider = CompactionProvider(Any[])
        agent = Agent(provider, Dict{String, JuliaForever.Tool}(), initial; history)
        seen = Ref{Any}()
        summarize(messages) = (seen[] = [convert(Dict{String, Any}, message) for message in messages]; "checkpoint")

        @test JuliaForever.compact!(agent, summarize) == "checkpoint"
        @test seen[] == initial[2:3]
        @test agent.messages == reference["before"]
        close(history)

        history = open(CompactionHistory.SQLite, joinpath(dir, "history.sqlite"))
        restored = Agent(provider, []; history)
        @test restored.messages == reference["before"]
        @test respond!(restored, "follow up") == "next answer"
        @test only(provider.requests) == reference["after"]
        close(history)
    end
end
