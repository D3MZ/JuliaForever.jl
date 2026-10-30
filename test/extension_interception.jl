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

@testset "terminal retains result interception and host events" begin
    reg = E.Registry()
    E.register!(reg, :one, E.Plugin(; tools=(InterceptTool(),), hooks=(:tool_result => (event -> ToolResult("updated")),)))
    snapshot = E.snapshot(reg)
    call = Dict("id" => "one", "type" => "function", "function" => Dict("name" => "intercept", "arguments" => "{}"))
    for history in (nothing, JuliaForever.History.Memory())
        provider = InterceptProvider([Dict("role" => "assistant", "content" => nothing, "tool_calls" => [call]), Dict("role" => "assistant", "content" => "done")], [])
        terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), String[])
        events = Any[]
        @test JuliaForever.run!(terminal, Agent(provider, snapshot; history), "go", snapshot; on_agent_event=event -> push!(events, event)) == 0
        @test provider.requests[2][end]["content"] == "updated"
        @test only(filter(event -> event.type == :tool_execution_end, events)).result.text == "updated"
    end
end


@testset "interception with deferred search and shell updates" begin
    for history in (nothing, JuliaForever.History.Memory())
        mktempdir() do dir
            events = Any[]
            reg = E.Registry()
            E.register!(reg, :hooks, E.Plugin(; hooks=(:tool_result => (event -> (push!(events, (:hook, event.tool_name)); nothing)),)))
            listener = E.listen(E.snapshot(reg); on_event=event -> begin
                event.type in (:tool_execution_start, :tool_execution_update, :tool_execution_end) && push!(events, (event.type, event.tool_name))
            end)
            calls = [Dict("id" => id, "type" => "function", "function" => Dict("name" => name, "arguments" => JSON3.write(args))) for (id, name, args) in [("search", "tool_search", (; query="intercept")), ("run", "intercept", (;)), ("shell", "bash", (; command="printf first; sleep 0.3; printf second"))]]
            replies = Any[Dict("role" => "assistant", "content" => nothing, "tool_calls" => [call]) for call in calls]
            push!(replies, Dict("role" => "assistant", "content" => "done"))
            p = InterceptProvider(replies, [])
            set = ToolSet([Bash(dir)], [InterceptTool()])
            @test respond!(Agent(p, set; history), "go"; on_agent_event=listener) == "done"
            @test filter(x -> x[1] == :hook, events) == [(:hook, "tool_search"), (:hook, "intercept"), (:hook, "bash")]
            for name in ("tool_search", "intercept", "bash")
                @test findfirst(==((:tool_execution_start, name)), events) < findfirst(==((:hook, name)), events) < findfirst(==((:tool_execution_end, name)), events)
            end
            @test any(==((:tool_execution_update, "bash")), events)
        end
    end
end

end
