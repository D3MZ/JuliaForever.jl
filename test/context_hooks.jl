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

end
