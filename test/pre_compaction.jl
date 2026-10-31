module PreCompactionTests

using Test, JuliaForever, JSON3
import JuliaForever.History as H

mutable struct Provider
    replies::Vector{Completion}
    requests::Vector{Any}
end
function JuliaForever.complete(provider::Provider, messages, tools)
    push!(provider.requests, deepcopy(messages))
    popfirst!(provider.replies)
end
reply(text, tokens) = Completion(Dict{String, Any}("role" => "assistant", "content" => text), Usage(tokens, 0, 0, 0, 0, tokens, 0.01), "stop", true, nothing)
policy() = JuliaForever.UsageCompaction(100, 20, JuliaForever.RecentTokens(0))
provider() = Provider([reply("first answer", 50), reply("second answer", 81), reply("third answer", 50)], Any[])

@testset "compact saved context before a prompt" begin
    if haskey(ENV, "PI_SOURCE")
        source = ENV["PI_SOURCE"]
        @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
        oracle = JSON3.read(read(`node $(joinpath(@__DIR__, "pre_compaction_pi.mjs")) $source`, String))
        @test length(oracle.high) == 1 && only(oracle.high).reason == "threshold" && !only(oracle.high).retry
        @test isempty(oracle.boundary) && isempty(oracle.disabled) && isempty(oracle.stale)
        @test [event.reason for event in oracle.retryAfterCancelled] == ["threshold", "threshold"]
    end
    for storage in (:memory, :sqlite)
        mktempdir() do root
            path = joinpath(root, "history.sqlite")
            history = storage == :memory ? H.Memory() : open(H.SQLite, path)
            model = provider()
            agent = Agent(model, []; history)
            @test respond!(agent, "first") == "first answer"
            @test respond!(agent, "second") == "second answer"
            if storage == :sqlite
                close(history)
                history = open(H.SQLite, path)
                agent = Agent(model, []; history)
            end
            summaries = []
            events = []
            result = respond!(agent, "third"; auto_compaction=policy(), summarize=messages -> (push!(summaries, deepcopy(messages)); "checkpoint"), on_agent_event=event -> push!(events, event))
            @test result == "third answer"
            @test length(summaries) == 1
            @test !occursin("third", JSON3.write(summaries))
            @test occursin("checkpoint", JSON3.write(last(model.requests)))
            @test last(last(model.requests))["content"] == "third"
            starts = [event.type for event in events]
            @test findfirst(==(:auto_compaction_start), starts) < findfirst(==(:agent_start), starts)
            restored = Agent(model, []; history)
            @test restored.messages == agent.messages
            storage == :sqlite && close(history)
        end
    end
    for (tokens, settings) in ((80, policy()), (81, JuliaForever.AutoCompaction(100, 20; enabled=false)), (81, JuliaForever.UsageCompaction(200, 20, JuliaForever.RecentTokens(0))))
        model = Provider([reply("first answer", 50), reply("second answer", tokens), reply("third answer", 50)], Any[])
        agent = Agent(model, []; history=H.Memory())
        respond!(agent, "first")
        respond!(agent, "second")
        summaries = Ref(0)
        @test respond!(agent, "third"; auto_compaction=settings, summarize=_ -> (summaries[] += 1; "unexpected")) == "third answer"
        @test summaries[] == 0 && occursin("first answer", JSON3.write(last(model.requests)))
    end
end

@testset "pre-prompt checks estimate missing usage and protect a cancelled request" begin
    model = Provider([reply("first answer", 75), reply(repeat("z", 40), 0), reply("third answer", 50)], Any[])
    agent = Agent(model, []; history=H.Memory())
    respond!(agent, "first")
    respond!(agent, "second")
    @test JuliaForever.preestimate(agent) == 87
    if haskey(ENV, "PI_SOURCE")
        oracle = JSON3.read(read(`node $(joinpath(@__DIR__, "pre_compaction_pi.mjs")) $(ENV["PI_SOURCE"])`, String))
        @test JuliaForever.preestimate(agent) == oracle.fallback.tokens
    end
    summaries = Ref(0)
    @test respond!(agent, "third"; auto_compaction=policy(), summarize=_ -> (summaries[] += 1; "checkpoint")) == "third answer"
    @test summaries[] == 1 && occursin("checkpoint", JSON3.write(last(model.requests)))

    emptyreply(text) = Completion(Dict{String, Any}("role" => "assistant", "content" => text), nothing, "stop", true, nothing)
    model = Provider([emptyreply("first answer"), emptyreply(repeat("z", 400)), reply("third answer", 50)], Any[])
    agent = Agent(model, []; history=H.Memory())
    respond!(agent, "first")
    respond!(agent, "second")
    if haskey(ENV, "PI_SOURCE")
        oracle = JSON3.read(read(`node $(joinpath(@__DIR__, "pre_compaction_pi.mjs")) $(ENV["PI_SOURCE"])`, String))
        @test JuliaForever.preestimate(agent) == oracle.unreported.tokens
    end
    summaries[] = 0
    @test respond!(agent, "third"; auto_compaction=policy(), summarize=_ -> (summaries[] += 1; "checkpoint")) == "third answer"
    @test summaries[] == 1 && occursin("checkpoint", JSON3.write(last(model.requests)))

    model = provider()
    history = H.Memory()
    agent = Agent(model, []; history)
    respond!(agent, "first")
    respond!(agent, "second")
    ready, release = Channel{Nothing}(1), Channel{Nothing}(1)
    task = Threads.@spawn respond!(agent, "third"; auto_compaction=policy(), summarize=_ -> (put!(ready, nothing); take!(release); "ignored"))
    @test timedwait(() -> isready(ready) || istaskdone(task), 10; pollint=0.01) == :ok
    @test isready(ready)
    if isready(ready)
        take!(ready)
        @test respond!(agent, "overlap") == :busy
        @test cancel!(agent)
        put!(release, nothing)
        @test fetch(task) == :cancelled && length(model.requests) == 2
        @test Agent(model, []; history).messages == agent.messages
        @test !occursin("<summary>", JSON3.write(agent.messages))
    else
        put!(release, nothing)
        wait(task)
    end
end

@testset "interactive pre-prompt compaction" begin
    python, tmux = Sys.which("python3"), Sys.which("tmux")
    if Sys.isunix() && !isnothing(python) && !isnothing(tmux)
        project = dirname(@__DIR__)
        julia = first(Base.julia_cmd().exec)
        command = addenv(`$python $(joinpath(@__DIR__, "pre_compaction_live.py")) $project $julia`, "JULIA_DEPOT_PATH" => join(DEPOT_PATH, ':'))
        @test success(run(ignorestatus(command)))
    else
        @test_skip false
    end
end

end
