module CompactionEditTests

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

@testset "skill refresh after compaction preserves the correct usage boundary" begin
    if haskey(ENV, "PI_SOURCE")
        source = ENV["PI_SOURCE"]
        @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
        oracle = JSON3.read(read(`node $(joinpath(@__DIR__, "compaction_edit_pi.mjs")) $source`, String))
        @test oracle.editedEstimate > 80 && oracle.editedChecks == ["threshold"]
        @test isempty(oracle.staleChecks) && isempty(oracle.smallChecks)
    end
    for (freshreply, large) in ((false, true), (true, true), (true, false))
        mktempdir() do root
            skill = joinpath(root, ".pi", "skills", "demo", "SKILL.md")
            mkpath(dirname(skill))
            description = repeat("s", large ? 400 : 4)
            write(skill, "---\nname: demo\ndescription: $description\n---\nDemo.\n")
            path = joinpath(root, "history.sqlite")
            history = open(H.SQLite, path)
            model = Provider([reply("first answer", 50), reply("second answer", 81), reply("third answer", large ? 50 : 981), reply("fourth answer", 50)], Any[])
            agent = Agent(model, [Read(root)]; history)
            @test respond!(agent, "first") == "first answer"
            @test respond!(agent, "second") == "second answer"
            policy = JuliaForever.UsageCompaction(100, 20, JuliaForever.RecentTokens(0))
            @test JuliaForever.autocompact!(agent, Usage(81, 0, 0, 0, 0, 81, nothing), policy, _ -> "initial checkpoint") == "initial checkpoint"
            freshreply && @test respond!(agent, "third") == "third answer"
            close(history)
            history = open(H.SQLite, path)
            agent = Agent(model, [Read(root)]; history)
            counts = JuliaForever.SessionInfo.counts(agent, history)
            before = (counts.user, counts.assistant, counts.total, counts.usage.input)
            skills = JuliaForever.Skills.load(root; home=root, agentdir=joinpath(root, "agent"))
            @test JuliaForever.refreshskills!(agent, skills) === nothing
            close(history)
            history = open(H.SQLite, path)
            agent = Agent(model, [Read(root)]; history)
            counts = JuliaForever.SessionInfo.counts(agent, history)
            @test (counts.user, counts.assistant, counts.total, counts.usage.input) == before
            summaries = Ref(0)
            selected = large ? policy : JuliaForever.UsageCompaction(1000, 20, JuliaForever.RecentTokens(0))
            result = respond!(agent, "next"; auto_compaction=selected, summarize=_ -> (summaries[] += 1; "updated checkpoint"))
            @test result == (freshreply ? "fourth answer" : "third answer")
            @test summaries[] == Int(freshreply && large)
            @test occursin(freshreply && large ? "updated checkpoint" : "initial checkpoint", JSON3.write(last(model.requests)))
            @test any(message -> get(message, "role", "") == "system" && occursin(description, get(message, "content", "")), last(model.requests))
            @test Agent(model, [Read(root)]; history).messages == agent.messages
            close(history)
        end
    end
end

end
