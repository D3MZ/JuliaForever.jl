module BeforeToolCases
using Test, JuliaForever, JSON3
const E = JuliaForever.Extensions
mutable struct Provider
    replies::Vector{Any}
    requests::Vector{Any}
end
function JuliaForever.complete(p::Provider, messages, tools)
    push!(p.requests, deepcopy(messages)); popfirst!(p.replies)
end
struct Echo <: JuliaForever.Tool end
JuliaForever.name(::Echo) = "echo"
JuliaForever.description(::Echo) = "echo"
JuliaForever.schema(::Echo) = Dict("type" => "object", "properties" => Dict())
JuliaForever.execute(::Echo, args) = ToolResult(args.value)
struct EmptyAware <: JuliaForever.Tool end
JuliaForever.name(::EmptyAware) = "emptyaware"
JuliaForever.description(::EmptyAware) = "count arguments"
JuliaForever.schema(::EmptyAware) = Dict("type" => "object", "properties" => Dict())
JuliaForever.execute(::EmptyAware, args) = ToolResult(string(length(args)))
@testset "before tool interception" begin
    reference = nothing
    if haskey(ENV, "PI_SOURCE")
        source = ENV["PI_SOURCE"]
        @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
        reference = JSON3.read(read(`node $(joinpath(@__DIR__, "before_tool_reference.mjs")) $source`, String))
    end
    for history in (nothing, JuliaForever.History.Memory()), mode in (:transform, :block, :error)
        seen = Any[]
        reg = E.Registry()
        E.register!(reg, :first, E.Plugin(; tools=(Echo(),), hooks=(:tool_call => (e -> begin
            push!(seen, e.input["value"]); e.input["value"] = "changed"
            mode == :error && error("broken")
            mode == :block ? E.Block("denied") : nothing
        end),)))
        E.register!(reg, :second, E.Plugin(; hooks=(:tool_call => (e -> (push!(seen, e.input["value"]); nothing)), :tool_result => (e -> (push!(seen, e.result.text); nothing)))))
        listener = E.listen(E.snapshot(reg))
        call = Dict("id" => "1", "type" => "function", "function" => Dict("name" => "echo", "arguments" => "{\"value\":\"original\"}"))
        p = Provider([Dict("role" => "assistant", "content" => nothing, "tool_calls" => [call]), Dict("role" => "assistant", "content" => "done")], [])
        @test respond!(Agent(p, E.snapshot(reg); history), "go"; on_agent_event=listener) == "done"
        if !isnothing(reference)
            expected = reference[string(mode)]
            @test seen[1:length(expected.seen)] == expected.seen
            @test mode == :transform ? expected.value == "changed" : expected.reason == (mode == :block ? "denied" : "broken")
        end
        @test seen == (mode == :transform ? ["original", "changed", "changed"] : ["original"])
        @test p.requests[2][end]["content"] == (mode == :transform ? "changed" : mode == :block ? "Error: denied" : "Error: broken")
    end
end
mutable struct StreamProvider
    replies::Vector{Any}
    requests::Vector{Any}
end
function JuliaForever.stream(p::StreamProvider, messages, tools; parameters=Dict(), on_event=identity)
    push!(p.requests, deepcopy(messages))
    result = popfirst!(p.replies)
    on_event((; type=:done, result))
    result
end

end
