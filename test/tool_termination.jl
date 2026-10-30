module ToolTerminationTests
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
JuliaForever.schema(::Echo) = Dict("type" => "object")
JuliaForever.execute(::Echo, args) = ToolResult("executed")
call(id) = Dict("id" => id, "type" => "function", "function" => Dict("name" => "echo", "arguments" => "{}"))
@testset "blocked tool batch termination" begin
    reference = haskey(ENV, "PI_SOURCE") ? JSON3.read(read(`node $(joinpath(@__DIR__, "tool_termination_reference.mjs")) $(ENV["PI_SOURCE"])`, String)) : nothing
    if reference !== nothing
        @test readchomp(`git -C $(ENV["PI_SOURCE"]) rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    end
    for mode in (:sequential, :parallel), recorded in (false, true), scenario in (:all, :mixed, :result)
        history = recorded ? JuliaForever.History.Memory() : nothing
        seen = String[]
        registry = E.Registry()
        E.register!(registry, :hooks, E.Plugin(; tools=(Echo(),), hooks=(
            :tool_call => (e -> e.tool_call_id == "one" || scenario == :all ? E.Block("denied"; terminate=true) : nothing),
            :tool_result => (e -> (push!(seen, e.tool_call_id); scenario == :result ? E.Terminate(ToolResult("changed")) : nothing)),
        )))
        snapshot = E.snapshot(registry)
        reply = Dict("role" => "assistant", "content" => nothing, "tool_calls" => [call("one"), call("two")])
        provider = Provider(Any[reply, Dict("role" => "assistant", "content" => "done")], Any[])
        agent = Agent(provider, snapshot; history)
        answer = respond!(agent, "go"; on_agent_event=E.listen(snapshot), tool_execution=mode)
        @test length(provider.requests) == (scenario == :mixed ? 2 : 1)
        @test answer == (scenario == :mixed ? "done" : nothing)
        @test seen == (scenario == :all ? String[] : ["two"])
        @test [m["content"] for m in agent.messages if m["role"] == "tool"] == (scenario == :all ? ["Error: denied", "Error: denied"] : scenario == :result ? ["Error: denied", "changed"] : ["Error: denied", "executed"])
        if reference !== nothing
            expected = reference["$mode:$scenario"]
            @test length(provider.requests) == expected.requests
            @test seen == expected.seen
            @test [replace(m["content"], r"^Error: " => "") for m in agent.messages if m["role"] == "tool"] == expected.messages
        end
        if history !== nothing
            restored = Agent(provider, snapshot; history)
            @test restored.messages == agent.messages
        end
    end
end
@testset "termination continuation and cancellation" begin
    for mode in (:sequential, :parallel), queued in (:none, :steer, :followup)
        mktempdir() do dir
            history = open(JuliaForever.History.SQLite, joinpath(dir, "history.sqlite"))
            try
                registry = E.Registry()
                E.register!(registry, :hooks, E.Plugin(; tools=(Echo(),), hooks=(:tool_call => (e -> E.Block("denied"; terminate=true)),)))
                snapshot = E.snapshot(registry)
                reply = Dict("role" => "assistant", "content" => nothing, "tool_calls" => [call("one")])
                provider = Provider(Any[reply, Dict("role" => "assistant", "content" => "done"), Dict("role" => "assistant", "content" => "continued")], Any[])
                agent = Agent(provider, snapshot; history)
                callback = E.listen(snapshot; on_event=e -> begin
                    if e.type == :tool_execution_end
                        queued == :steer && steer!(agent, "steer")
                        queued == :followup && followup!(agent, "followup")
                    end
                end)
                @test respond!(agent, "go"; on_agent_event=callback, tool_execution=mode) == (queued == :none ? nothing : "done")
                @test length(provider.requests) == (queued == :none ? 1 : 2)
                restored = Agent(provider, snapshot; history)
                @test restored.messages == agent.messages
                if queued == :none
                    @test continue!(restored; on_agent_event=E.listen(snapshot), tool_execution=mode) == "done"
                    @test length(provider.requests) == 2
                end
            finally
                close(history)
            end
        end
    end
    for mode in (:sequential, :parallel)
        registry = E.Registry()
        holder = Ref{Any}()
        E.register!(registry, :hooks, E.Plugin(; tools=(Echo(),), hooks=(:tool_call => (e -> (cancel!(holder[]); E.Block("denied"; terminate=true))),)))
        snapshot = E.snapshot(registry)
        reply = Dict("role" => "assistant", "content" => nothing, "tool_calls" => [call("one")])
        provider = Provider(Any[reply], Any[])
        agent = holder[] = Agent(provider, snapshot)
        @test respond!(agent, "go"; on_agent_event=E.listen(snapshot), tool_execution=mode) == :cancelled
        @test only([m["content"] for m in agent.messages if m["role"] == "tool"]) == "Error: Operation cancelled"
    end
end

@testset "result hooks preserve and override termination" begin
    for clear in (false, true)
        registry = E.Registry()
        E.register!(registry, :first, E.Plugin(; tools=(Echo(),), hooks=(:tool_result => (e -> E.Terminate(ToolResult("first"))),)))
        E.register!(registry, :second, E.Plugin(; hooks=(:tool_result => (e -> clear ? E.Proceed(ToolResult("second")) : ToolResult("second")),)))
        snapshot = E.snapshot(registry)
        reply = Dict("role" => "assistant", "content" => nothing, "tool_calls" => [call("one")])
        provider = Provider(Any[reply, Dict("role" => "assistant", "content" => "done")], Any[])
        agent = Agent(provider, snapshot)
        @test respond!(agent, "go"; on_agent_event=E.listen(snapshot)) == (clear ? "done" : nothing)
        @test length(provider.requests) == (clear ? 2 : 1)
        @test only([m["content"] for m in agent.messages if m["role"] == "tool"]) == "second"
    end
end

end
