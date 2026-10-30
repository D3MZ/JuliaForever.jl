module ContextHookCases
using Test, JuliaForever, JSON3, Distributed
const J = JuliaForever
const E = J.Extensions
mutable struct Provider
    requests::Vector{Any}
end
function J.complete(p::Provider, messages, tools)
    push!(p.requests, deepcopy(messages))
    Dict("role" => "assistant", "content" => "done")
end
@testset "Pi context chaining" begin
    initial = Dict{String, Any}[
        Dict("role" => "system", "content" => "prompt", "timestamp" => 1),
        Dict("role" => "user", "content" => "hello"),
        Dict("role" => "system", "content" => "extra", "timestamp" => 2),
        Dict("role" => "assistant", "content" => "answer"),
    ]
    original = deepcopy(initial)
    seen = Any[]
    registry = E.Registry()
    E.register!(registry, :fixture, E.Plugin(; hooks=(
        :context => (e -> (push!(seen, deepcopy(e.messages)); push!(e.messages, Dict("role" => "user", "content" => "injected")); nothing)),
        :context => (e -> (e.messages[1]["content"] = "edited"; error("broken"))),
        :context => (e -> (push!(seen, deepcopy(e.messages)); nothing)),
        :context_with_system => (e -> (push!(seen, deepcopy(e.messages)); nothing)),
    )))
    listener = E.listen(E.snapshot(registry))
    result = J.contextmessages(listener, initial)
    @test initial == original
    @test getindex.(seen[1], "role") == ["user", "assistant"]
    @test getindex.(result, "content") == ["prompt\n\nextra", "edited", "answer", "injected"]
    @test getproperty.(E.failures(listener), :event) == [:context]
    if haskey(ENV, "PI_SOURCE")
        @test readchomp(`git -C $(ENV["PI_SOURCE"]) rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
        reference = JSON3.read(read(`node $(joinpath(@__DIR__, "context_hooks_pi.mjs")) $(ENV["PI_SOURCE"])`, String), Dict{String, Any})
        actual = Dict("seen" => seen, "result" => result, "original" => initial, "errors" => ["context"])
        @test JSON3.read(JSON3.write(actual)) == JSON3.read(JSON3.write(reference))
    end
end

@testset "request context hooks" begin
    registry = E.Registry()
    seen = Any[]
    E.register!(registry, :hooks, E.Plugin(; hooks=(
        :context => (event -> (push!(seen, deepcopy(event.messages)); push!(event.messages, Dict("role" => "user", "content" => "injected")); nothing)),
        :context_with_system => (event -> (push!(seen, deepcopy(event.messages)); nothing)),
    )))
    listener = E.listen(E.snapshot(registry))
    provider = Provider([])
    agent = Agent(provider, E.snapshot(registry), Dict{String, Any}[Dict("role" => "system", "content" => "prompt")])
    @test respond!(agent, "hello"; on_agent_event=listener) == "done"
    @test getindex.(seen[1], "role") == ["user"]
    @test getindex.(seen[2], "role") == ["system", "user", "user"]
    @test getindex.(provider.requests[1], "content") == ["prompt", "hello", "injected"]
    @test !any(message -> get(message, "content", "") == "injected", agent.messages)
end
mutable struct StreamingProvider
    requests::Vector{Any}
    replies::Vector{Any}
end
function J.stream(p::StreamingProvider, messages, tools; parameters=Dict(), on_event=identity)
    push!(p.requests, deepcopy(messages))
    J.Completion(popfirst!(p.replies), nothing, "stop", J.Finished(), nothing)
end

mutable struct CompactProvider
    requests::Vector{Any}
    replies::Vector{Completion}
end
function J.complete(p::CompactProvider, messages, tools)
    push!(p.requests, deepcopy(messages))
    popfirst!(p.replies)
end

@testset "context hooks stay temporary through compaction and replay" begin
    reply(text, tokens) = Completion(Dict{String, Any}("role" => "assistant", "content" => text), Usage(tokens, 0, 0, 0, 0, tokens, nothing), "stop", true, nothing)
    provider = CompactProvider([], [reply("one", 50), reply("two", 81), reply("three", 50), reply("four", 50)])
    events = Any[]
    registry = E.Registry()
    E.register!(registry, :fixture, E.Plugin(; hooks=(:context => event -> (push!(event.messages, Dict("role" => "user", "content" => "temporary")); nothing),)))
    listener = E.listen(E.snapshot(registry); on_event=event -> push!(events, event))
    history = J.History.Memory()
    agent = Agent(provider, Dict{String, J.Tool}(), Dict{String, Any}[Dict("role" => "system", "content" => "base")]; history)
    @test respond!(agent, "first"; on_agent_event=listener) == "one"
    @test respond!(agent, "second"; on_agent_event=listener) == "two"
    summaries = Any[]
    policy = J.ChangingCompaction(() -> J.UsageCompaction(100, 20, J.RecentTokens(0)))
    @test respond!(agent, "third"; on_agent_event=listener, auto_compaction=policy, summarize=messages -> (push!(summaries, deepcopy(messages)); "checkpoint")) == "three"
    @test length(summaries) == 1 && !occursin("temporary", repr(summaries))
    @test occursin("checkpoint", repr(provider.requests[3])) && occursin("temporary", repr(provider.requests[3]))
    @test [event.type for event in events if event.type in (:auto_compaction_start, :auto_compaction_end)] == [:auto_compaction_start, :auto_compaction_end]
    @test !occursin("temporary", repr(J.History.snapshot(history)))
    restored = Agent(provider, []; history)
    @test restored.messages == agent.messages
    @test respond!(restored, "fourth"; on_agent_event=listener) == "four"
    @test occursin("checkpoint", repr(provider.requests[4])) && occursin("temporary", repr(provider.requests[4]))
    @test !occursin("temporary", repr(J.History.snapshot(history)))
end

@testset "streamed continuation and persisted history" begin
    mktempdir() do dir
        call = Dict("id" => "one", "type" => "function", "function" => Dict("name" => "write", "arguments" => "{\"path\":\"a\",\"content\":\"ok\"}"))
        replies = Any[Dict("role" => "assistant", "content" => nothing, "tool_calls" => [call]), Dict("role" => "assistant", "content" => "done"), Dict("role" => "assistant", "content" => "followed")]
        provider = StreamingProvider([], replies)
        registry = E.Registry()
        function transform(e)
            for message in e.messages
                get(message, "content", "") == "queued" && (message["content"] = "changed queued")
            end
            (; messages=[e.messages; Dict("role" => "user", "content" => "temporary")])
        end
        E.register!(registry, :fixture, E.Plugin(; tools=(Write(dir),), hooks=(:context => transform,)))
        snapshot = E.snapshot(registry)
        history = J.History.Memory()
        agent = Agent(provider, snapshot; history)
        listener = E.listen(snapshot; on_event=e -> e.type == :tool_execution_start && J.followup!(agent, "queued"))
        @test respond!(agent, "start"; on_event=identity, on_agent_event=listener) == "followed"
        @test length(provider.requests) == 3
        @test any(m -> get(m, "content", "") == "changed queued", provider.requests[3])
        @test any(m -> get(m, "content", "") == "queued", agent.messages)
        @test all(request -> count(m -> get(m, "content", "") == "temporary", request) == 1, provider.requests)
        @test read(joinpath(dir, "a"), String) == "ok"
        @test !occursin("temporary", repr(J.History.snapshot(history)))
        @test !any(m -> get(m, "content", "") == "temporary", agent.messages)
    end
end

@testset "replacement and system removal" begin
    registry = E.Registry()
    E.register!(registry, :fixture, E.Plugin(; hooks=(
        :context => (e -> (; messages=[last(e.messages)])),
        :context_with_system => (e -> (; messages=e.messages[2:end])),
        :context_with_system => (e -> (push!(e.messages, Dict("role" => "user", "content" => "last")); nothing)),
    )))
    listener = E.listen(E.snapshot(registry))
    initial = Dict{String, Any}[Dict("role" => "system", "content" => "system", "timestamp" => 1), Dict("role" => "user", "content" => "first"), Dict("role" => "user", "content" => "second")]
    result = J.contextmessages(listener, initial)
    @test getindex.(result, "content") == ["second", "last"]
    @test getproperty.(E.failures(listener), :event) == [:context_with_system]
    @test length(initial) == 3
end

@testset "executor request hooks" begin
    execution = J.Execution
    context = "context-hook-test"
    provider = Provider([])
    @test execution.install!(context, provider, [])
    pool = execution.Executor(Distributed.myid())
    try
        registry = E.Registry()
        E.register!(registry, :fixture, E.Plugin(; hooks=(:context => (e -> (e.messages[1]["content"] = "changed"; nothing)),)))
        agent = Agent(nothing, [])
        result = respond!(agent, "original"; executor=pool, context, on_agent_event=E.listen(E.snapshot(registry)))
        @test result.value == "done"
        @test only(provider.requests)[1]["content"] == "changed"
        @test agent.messages[1]["content"] == "original"
    finally
        close(pool)
        execution.uninstall!(context)
    end
end

mutable struct BetweenProvider
    replies::Vector{Completion}
    requests::Vector{Any}
end
function J.complete(provider::BetweenProvider, messages, tools)
    push!(provider.requests, (; messages=deepcopy(messages), names=[J.name(tool) for tool in values(tools)]))
    popfirst!(provider.replies)
end

@testset "context hooks across between-tool compaction and replay" begin
    reply(text, tokens; calls=[]) = Completion(Dict{String, Any}("role" => "assistant", "content" => text, "tool_calls" => calls), Usage(tokens, 0, 0, 0, 0, tokens, nothing), isempty(calls) ? "stop" : "tool_calls", true, nothing)
    for remote in (false, true)
        mktempdir() do root
            write(joinpath(root, "target.txt"), repeat("x", 400))
            call = Dict("id" => "read-large", "type" => "function", "function" => Dict("name" => "read", "arguments" => JSON3.write((; path="target.txt"))))
            provider = BetweenProvider([reply("one", 50), reply("two", 50), reply(nothing, 50; calls=[call]), reply("done", 20), reply("replayed", 20)], [])
            history = J.History.Memory()
            agent = Agent(provider, [Read(root)]; history)
            events = Any[]
            registry = E.Registry()
            E.register!(registry, :fixture, E.Plugin(; hooks=(:context_with_system => event -> begin
                event.messages[1]["sections"] = Dict("temporary" => "request-only instructions")
                event.messages[1]["toolsAdded"] = []
                push!(event.messages, Dict("role" => "user", "content" => "request-only input"))
                nothing
            end,)))
            listener = E.listen(E.snapshot(registry); on_event=event -> push!(events, event))
            id = "context-between-$(remote)"
            executor = remote ? J.Execution.Executor(Distributed.myid()) : nothing
            remote && @test J.Execution.install!(id, provider, [Read(root)])
            function turn(agent, prompt; options...)
                result = remote ? respond!(agent, prompt; executor, context=id, on_agent_event=listener, options...) : respond!(agent, prompt; on_agent_event=listener, options...)
                remote ? result.value : result
            end
            try
                @test turn(agent, "first") == "one"
                @test turn(agent, "second") == "two"
                empty!(events)
                summaries = Any[]
                @test turn(agent, "third"; auto_compaction=J.AutoCompaction(100, 0), summarize=messages -> (push!(summaries, deepcopy(messages)); "checkpoint")) == "done"
                @test length(summaries) == 1 && !occursin("request-only", repr(summaries))
                @test all(isempty(request.names) for request in provider.requests)
                request = last(provider.requests).messages
                @test occursin("checkpoint", repr(request)) && occursin("request-only", repr(request))
                @test any(message -> get(message, "role", "") == "tool" && occursin(repeat("x", 400), message["content"]), request)
                types = getproperty.(events, :type)
                @test findfirst(==(:tool_execution_end), types) < findfirst(==(:auto_compaction_start), types) < findlast(==(:turn_start), types)
                @test !occursin("request-only", repr(J.History.snapshot(history)))
                restored = Agent(provider, [Read(root)]; history)
                @test restored.messages == agent.messages
                @test turn(restored, "after") == "replayed"
                @test occursin("checkpoint", repr(last(provider.requests).messages)) && !occursin("request-only", repr(J.History.snapshot(history)))
            finally
                if remote
                    close(executor)
                    J.Execution.uninstall!(id)
                end
            end
        end
    end
end

mutable struct LiveEntryProvider
    model::String
    requests::Vector{Any}
end
function J.complete(provider::LiveEntryProvider, messages, tools; parameters=Dict())
    push!(provider.requests, deepcopy(messages))
    Completion(Dict{String, Any}("role" => "assistant", "content" => "answer"), nothing, "stop", true, nothing)
end
function J.stream(provider::LiveEntryProvider, messages, tools; parameters=Dict(), on_event=identity)
    result = J.complete(provider, messages, tools; parameters)
    on_event((; type=:text, text="answer"))
    on_event((; type=:done, result))
    result
end

@testset "request context stays out of mixed live session entries" begin
    mktempdir() do root
        registry = E.Registry()
        E.register!(registry, :fixture, E.Plugin(; hooks=(:context => event -> (push!(event.messages, Dict("role" => "user", "content" => "request-only input")); nothing),)))
        snapshot = E.snapshot(registry)
        provider = LiveEntryProvider("fixture", [])
        history = J.History.Memory()
        agent = Agent(provider, []; history)
        @test respond!(agent, "direct"; on_agent_event=E.listen(snapshot)) == "answer"
        text = J.Terminal(IOBuffer(), IOBuffer(), String[], J.TextMode("fixture"))
        @test J.run!(text, agent, "text", snapshot) == 0
        json = J.Terminal(IOBuffer(), IOBuffer(), String[], J.JSONMode("fixture"))
        @test J.run!(json, agent, "json", snapshot) == 0
        @test length(provider.requests) == 3 && all(request -> any(message -> get(message, "content", "") == "request-only input", request), provider.requests)
        terminal = J.Terminal(IOBuffer(), IOBuffer(), String[], J.RPCMode("fixture", "off"))
        session = J.Headless.Session(terminal, agent, nothing, Ref(history), nothing, root)
        entries = J.Headless.handle!(session, J.Headless.GetEntries(nothing)).fields.data.entries
        users = [entry for entry in entries if entry["type"] == "message" && get(entry["message"], "role", "") == "user"]
        @test [join(get(block, "text", "") for block in entry["message"]["content"]) for entry in users] == ["direct", "text", "json"]
        @test !occursin("request-only input", JSON3.write(entries))
        @test !occursin("request-only input", repr(J.History.snapshot(history)))
    end
end

end
