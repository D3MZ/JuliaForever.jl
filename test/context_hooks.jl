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

mutable struct BetweenProvider
    replies::Vector{Completion}
    requests::Vector{Any}
end
function J.complete(provider::BetweenProvider, messages, tools)
    push!(provider.requests, (; messages=deepcopy(messages), names=[J.name(tool) for tool in values(tools)]))
    popfirst!(provider.replies)
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

mutable struct CancelProvider
    calls::Int
end
function J.complete(provider::CancelProvider, messages, tools)
    provider.calls += 1
    Dict("role" => "assistant", "content" => "unexpected")
end
function J.stream(provider::CancelProvider, messages, tools; parameters=Dict(), on_event=identity)
    provider.calls += 1
    J.Completion(Dict{String, Any}("role" => "assistant", "content" => "unexpected"), nothing, "stop", J.Finished(), nothing)
end

end
