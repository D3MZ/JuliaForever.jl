module ToolCompactionTests

using Test, JuliaForever, JSON3, Distributed
import JuliaForever as J
import JuliaForever.History as H

mutable struct Provider
    replies::Vector{Completion}
    requests::Vector{Any}
end
function J.complete(provider::Provider, messages, tools; parameters=Dict())
    push!(provider.requests, deepcopy(messages))
    popfirst!(provider.replies)
end
function reply(text; calls=[], finish="stop", tokens=50)
    message = Dict{String, Any}("role" => "assistant", "content" => text)
    isempty(calls) || (message["tool_calls"] = calls)
    Completion(message, Usage(tokens, 0, 0, 0, 0, tokens, nothing), finish, true, nothing)
end
function setup(root, history; chars=400, secondtokens=50)
    write(joinpath(root, "target.txt"), repeat("x", chars))
    call = Dict("id" => "read-large", "type" => "function", "function" => Dict("name" => "read", "arguments" => JSON3.write((; path="target.txt"))))
    provider = Provider([reply("first answer"), reply("second answer"; tokens=secondtokens), reply(nothing; calls=[call], finish="tool_calls"), reply("done"; tokens=20)], Any[])
    agent = Agent(provider, [Read(root)]; history)
    respond!(agent, "first")
    respond!(agent, "second")
    agent, provider
end
policy(; enabled=true) = J.AutoCompaction(100, 0; enabled)

@testset "compact between tool turns" begin
    for storage in (:direct, :memory, :sqlite)
        mktempdir() do root
            path = joinpath(root, "history.sqlite")
            history = storage == :direct ? nothing : storage == :memory ? H.Memory() : open(H.SQLite, path)
            agent, provider = setup(root, history)
            events = []
            summaries = []
            result = respond!(agent, "third"; auto_compaction=policy(), summarize=messages -> (push!(summaries, deepcopy(messages)); "checkpoint"), on_agent_event=event -> push!(events, event))
            @test result == "done" && length(summaries) == 1
            request = last(provider.requests)
            @test occursin("checkpoint", JSON3.write(request)) && any(message -> get(message, "role", "") == "tool" && occursin(repeat("x", 400), message["content"]), request)
            types = [event.type for event in events]
            start, finish = findfirst(==(:auto_compaction_start), types), findfirst(==(:auto_compaction_end), types)
            @test !isnothing(start) && !isnothing(finish) && types[start-1] == :turn_end && types[finish+1] == :turn_start
            if storage == :sqlite
                expected = deepcopy(agent.messages)
                close(history)
                restored = open(H.SQLite, path)
                @test Agent(provider, [Read(root)]; history=restored).messages == expected
                close(restored)
            end
        end
    end
end

@testset "tool compaction honors the threshold, failures, and cancellation" begin
    for (chars, enabled, failure) in ((40, true, false), (200, true, false), (400, false, false), (400, true, true))
        mktempdir() do root
            agent, provider = setup(root, H.Memory(); chars)
            summaries = Ref(0)
            summarize = _ -> (summaries[] += 1; failure ? H.Rejected(:summary_failed) : "checkpoint")
            @test respond!(agent, "third"; auto_compaction=policy(; enabled), summarize) == "done"
            @test summaries[] == Int(failure) && occursin("first answer", JSON3.write(last(provider.requests)))
        end
    end
    mktempdir() do root
        agent, provider = setup(root, H.Memory())
        @test respond!(agent, "third"; auto_compaction=policy(), summarize=_ -> (steer!(agent, "queued"); "checkpoint")) == "done"
        @test any(message -> get(message, "role", "") == "user" && get(message, "content", "") == "queued", last(provider.requests))
        @test isempty(agent.state.steering)
    end
    mktempdir() do root
        agent, provider = setup(root, H.Memory())
        provider.replies = [reply("first turn"; tokens=101), reply("done"; tokens=20)]
        events = []
        queued = Ref(false)
        callback = event -> begin
            push!(events, event)
            if event.type == :message_end && get(event.message, "role", "") == "assistant" && !queued[]
                queued[] = true
                steer!(agent, "queued")
            end
        end
        @test respond!(agent, "third"; auto_compaction=policy(), summarize=_ -> "checkpoint", on_agent_event=callback) == "done"
        @test occursin("checkpoint", JSON3.write(last(provider.requests))) && last(last(provider.requests))["content"] == "queued"
        types = [event.type for event in events]
        start = findfirst(==(:auto_compaction_start), types)
        @test !isnothing(start) && types[start-1] == :turn_end
    end
    mktempdir() do root
        history = H.Memory()
        agent, provider = setup(root, history)
        events = []
        callback = event -> begin
            push!(events, event)
            event.type == :auto_compaction_start && cancel!(agent)
        end
        @test respond!(agent, "third"; auto_compaction=policy(), summarize=_ -> "unexpected", on_agent_event=callback) == :cancelled
        @test length(provider.requests) == 3 && !occursin("checkpoint", JSON3.write(agent.messages))
        @test Agent(provider, [Read(root)]; history).messages == agent.messages
        @test only(event for event in events if event.type == :auto_compaction_end).result == :cancelled
    end
end

@testset "executor compacts before prompts and between tool turns" begin
    for secondtokens in (50, 101)
        mktempdir() do root
            agent, provider = setup(root, H.Memory(); secondtokens)
            context = "tool-compaction-$(secondtokens)"
            @test J.Execution.install!(context, provider, [Read(root)])
            executor = J.Execution.Executor(myid())
            events = []
            try
                result = respond!(agent, "third"; executor, context, auto_compaction=policy(), summarize=_ -> "checkpoint", on_agent_event=event -> push!(events, event))
                @test result.value == "done"
                @test occursin("checkpoint", JSON3.write(last(provider.requests)))
                types = [event.type for event in events]
                start = findfirst(==(:auto_compaction_start), types)
                @test !isnothing(start) && (secondtokens == 50 ? types[start-1] == :turn_end : start < findfirst(==(:agent_start), types))
            finally
                close(executor)
                J.Execution.uninstall!(context)
            end
        end
    end
end

end
