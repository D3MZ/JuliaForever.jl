module OverflowTests

using Test, JuliaForever, JSON3, HTTP
import JuliaForever.History as H
import JuliaForever.Conversation as C
import JuliaForever.Extensions as E

mutable struct Provider
    replies::Vector{Any}
    requests::Vector{Any}
end

function JuliaForever.complete(provider::Provider, messages, tools)
    push!(provider.requests, deepcopy(messages))
    popfirst!(provider.replies)
end

struct CountingTool <: JuliaForever.Tool
    calls::Base.RefValue{Int}
end
JuliaForever.name(::CountingTool) = "counting_tool"
JuliaForever.execute(tool::CountingTool, args) = (tool.calls[] += 1; ToolResult("tool result"))

failure(error=ProviderStatus(413)) = Completion(Dict{String, Any}("role" => "assistant", "content" => "partial"), nothing, nothing, false, error)
answer(text="done") = Dict{String, Any}("role" => "assistant", "content" => text)
policy() = JuliaForever.AutoCompaction(100, 20)
initial() = Dict{String, Any}[
    Dict("role" => "system", "content" => "instructions"),
    Dict("role" => "user", "content" => "old request"),
    Dict("role" => "assistant", "content" => "old answer"),
    Dict("role" => "system", "content" => "extra instructions"),
]

@testset "overflow: retry once with a durable compacted context" begin
    if haskey(ENV, "PI_SOURCE")
        reference = JSON3.read(read(`node $(joinpath(@__DIR__, "overflow_pi.mjs")) $(ENV["PI_SOURCE"])`, String))
        @test reference.detection == [true, true, false, false]
        @test (reference.first, reference.second, reference.attempts, reference.omissions, reference.failed, reference.noProgress) == (true, false, 1, 1, true, true)
        @test (reference.liveResult.retry, reference.liveResult.omitted, reference.liveResult.compacted, reference.liveResult.failedVisible) == (true, true, true, false)
        @test [(event.reason, event.willRetry) for event in reference.liveResult.ends] == [("overflow", true)]
    end
    for storage in (:none, :memory, :sqlite)
        mktempdir() do dir
            path = joinpath(dir, "history.sqlite")
            history = storage == :none ? nothing : storage == :memory ? H.Memory() : open(H.SQLite, path)
            provider = Provider(Any[failure(), answer()], Any[])
            agent = Agent(provider, [], initial(); history)
            seen = Ref{Any}()
            events = Any[]
            registry = E.Registry()
            E.register!(registry, :watch, E.Plugin(; hooks=(:message_end => (event -> push!(events, event)),)))
            listener = E.listen(E.snapshot(registry))
            image = Image("image/png", "aW1hZ2U=")
            prompt = C.ImagePrompt("describe", [image])
            result = respond!(agent, prompt; auto_compaction=policy(), summarize=messages -> (seen[] = [convert(Dict{String, Any}, m) for m in messages]; "checkpoint"), on_agent_event=listener)
            @test result == "done"
            @test seen[] == initial()[2:3]
            @test length(provider.requests) == 2
            request = provider.requests[2]
            @test [m["role"] for m in request] == ["system", "system", "user", "user"]
            @test [m["content"] for m in request[1:2]] == ["instructions", "extra instructions"]
            @test request[3]["content"] == JuliaForever.summaryprefix * "checkpoint" * JuliaForever.summarysuffix
            @test request[4]["content"] == "describe"
            @test request[4]["images"] == [Dict("mime" => image.mime, "data" => image.data)]
            @test count(event -> get(event.message, "content", nothing) == "partial", events) == 1
            @test count(event -> get(event.message, "content", nothing) == "done", events) == 1
            @test !any(m -> get(m, "content", nothing) == "partial", agent.messages)
            if storage != :none
                expected = deepcopy(agent.messages)
                if storage == :sqlite
                    close(history)
                    history = open(H.SQLite, path)
                end
                restored = Agent(provider, []; history)
                @test restored.messages == expected
                @test restored.state.phase == C.Complete
                storage == :sqlite && close(history)
            end
        end
    end
    mktempdir() do dir
        skill = joinpath(dir, ".pi", "skills", "context", "SKILL.md")
        mkpath(dirname(skill))
        write(skill, "---\nname: context\ndescription: preserve this skill during recovery\n---\n")
        cd(dir) do
            withenv("HOME" => dir, "PI_CODING_AGENT_DIR" => joinpath(dir, "agent"), "JF_INSTRUCTIONS_DIR" => nothing) do
                provider = Provider(Any[failure(), answer()], Any[])
                seed = Agent(provider, [Read(dir)])
                messages = JuliaForever.initial(seed, nothing)
                append!(messages, C.Message[C.RawMessage(Dict("role" => "user", "content" => "old request")), C.RawMessage(Dict("role" => "assistant", "content" => "old answer"))])
                history = H.Memory()
                agent = Agent(provider, seed.tools, messages; history)
                @test respond!(agent, "current"; auto_compaction=policy(), summarize=_ -> "checkpoint") == "done"
                @test any(message -> message["role"] == "system" && occursin("preserve this skill during recovery", message["content"]), provider.requests[2])
                @test Agent(provider, []; history).messages == agent.messages
            end
        end
    end
end

end
