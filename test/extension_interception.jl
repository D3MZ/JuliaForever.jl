module ExtensionInterceptionCases

using Test, JuliaForever, JSON3
const E = JuliaForever.Extensions
mutable struct InterceptProvider
    replies::Vector{Any}
    requests::Vector{Any}
end
function JuliaForever.complete(p::InterceptProvider, messages, tools)
    push!(p.requests, deepcopy(messages))
    popfirst!(p.replies)
end
function JuliaForever.stream(p::InterceptProvider, messages, tools; parameters=Dict(), on_event=identity)
    message = JuliaForever.complete(p, messages, tools)
    Completion(message, nothing, haskey(message, "tool_calls") ? "tool_calls" : "stop", true, nothing)
end
struct InterceptTool <: JuliaForever.Tool end
JuliaForever.name(::InterceptTool) = "intercept"
JuliaForever.description(::InterceptTool) = "test"
JuliaForever.schema(::InterceptTool) = Dict("type" => "object", "properties" => Dict())
JuliaForever.execute(::InterceptTool, args) = ToolResult("original")
@testset "Pi tool result handler chaining" begin
    reference = (; seen=["original", "first", "last"], iserror=true, errors=["broken"])
    if haskey(ENV, "PI_SOURCE")
        source = ENV["PI_SOURCE"]
        @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
        reference = JSON3.read(read(`node $(joinpath(@__DIR__, "extension_interception_reference.mjs")) $source`, String))
    end
    for history in (nothing, JuliaForever.History.Memory())
        seen = Any[]
        reg = E.Registry()
        E.register!(reg, :one, E.Plugin(; tools=(InterceptTool(),), hooks=(:tool_result => (event -> (push!(seen, event.result.text); ToolResult("first"))), :tool_result => (event -> error("broken")))))
        E.register!(reg, :two, E.Plugin(; hooks=(:tool_result => (event -> (push!(seen, event.result.text); ToolFailure("last"))),)))
        listener = E.listen(E.snapshot(reg); on_event=event -> event.type == :tool_execution_end && push!(seen, event.result.text))
        call = Dict("id" => "one", "type" => "function", "function" => Dict("name" => "intercept", "arguments" => "{}"))
        p = InterceptProvider([Dict("role" => "assistant", "content" => nothing, "tool_calls" => [call]), Dict("role" => "assistant", "content" => "done")], [])
        @test respond!(Agent(p, E.snapshot(reg); history), "go"; on_agent_event=listener) == "done"
        @test seen == reference.seen
        @test p.requests[2][end]["content"] == "Error: last"
        @test p.requests[2][end]["is_error"] == reference.iserror
        @test [sprint(showerror, failure.exception) for failure in E.failures(listener)] == reference.errors
    end
end

end
