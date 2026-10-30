module ContextToolCases

using Test, JuliaForever, JSON3, Distributed
const J = JuliaForever
const E = J.Extensions
const X = J.Execution

mutable struct Provider
    requests::Vector{Any}
    replies::Vector{Any}
end

function reply(message, tools)
    calls = [Dict("id" => id, "type" => "function", "function" => Dict("name" => name, "arguments" => JSON3.write(arguments))) for (id, name, arguments) in tools]
    Dict{String, Any}("role" => "assistant", "content" => message, "tool_calls" => calls)
end

function J.complete(provider::Provider, messages, tools)
    push!(provider.requests, (; messages=deepcopy(messages), names=[J.name(tool) for tool in values(tools)]))
    popfirst!(provider.replies)
end
function J.stream(provider::Provider, messages, tools; parameters=Dict(), on_event=identity)
    answer = J.complete(provider, messages, tools)
    J.Completion(answer, nothing, "stop", J.Finished(), nothing)
end

function registry()
    registry = E.Registry()
    E.register!(registry, :fixture, E.Plugin(; hooks=(:context_with_system => event -> begin
        push!(event.messages, Dict("role" => "system", "content" => "later", "toolsRemoved" => [Dict("name" => "write")], "toolsAdded" => [Dict("name" => "ghost", "description" => "Ghost", "parameters" => Dict("type" => "object", "properties" => Dict()))], "timestamp" => 1))
        nothing
    end,)))
    E.snapshot(registry)
end

function provider()
    calls = [("missing", "ghost", (;)), ("allowed", "write", (; path="written", content="ok"))]
    Provider([], [reply(nothing, calls), reply("done", [])])
end

@testset "context tool declarations and execution permissions" begin
    for recorded in (false, true), streaming in (false, true)
        mktempdir() do dir
            provider = ContextToolCases.provider()
            snapshot = registry()
            history = recorded ? J.History.Memory() : nothing
            agent = Agent(provider, Dict{String, J.Tool}("write" => Write(dir)), Dict{String, Any}[Dict("role" => "system", "content" => "base")]; history)
            @test respond!(agent, "start"; on_agent_event=E.listen(snapshot), on_event=streaming ? identity : nothing) == "done"
            @test all(request -> request.names == ["ghost"], provider.requests)
            @test read(joinpath(dir, "written"), String) == "ok"
            results = filter(message -> get(message, "role", "") == "tool", agent.messages)
            @test only(filter(message -> message["tool_call_id"] == "missing", results))["is_error"]
            @test !only(filter(message -> message["tool_call_id"] == "allowed", results))["is_error"]
            @test haskey(agent.tools, "write") && !haskey(agent.tools, "ghost")
            @test count(message -> get(message, "role", "") == "system", agent.messages) == 1
            @test !any(message -> haskey(message, "toolsAdded") || haskey(message, "toolsRemoved"), agent.messages)
        end
    end
end

@testset "executor permissions and transformed declarations" begin
    mktempdir() do dir
        provider = ContextToolCases.provider()
        id = "context-tool-executor"
        @test X.install!(id, provider, [Write(dir)])
        executor = X.Executor(myid())
        try
            snapshot = registry()
            history = J.History.Memory()
            agent = Agent(nothing, Dict{String, J.Tool}(), Dict{String, Any}[Dict("role" => "system", "content" => "base")]; history)
            @test respond!(agent, "start"; executor, context=id, on_agent_event=E.listen(snapshot)).value == "done"
            @test all(request -> request.names == ["ghost"], provider.requests)
            @test read(joinpath(dir, "written"), String) == "ok"
            results = filter(message -> get(message, "role", "") == "tool", agent.messages)
            @test only(filter(message -> message["tool_call_id"] == "missing", results))["is_error"]
            @test !only(filter(message -> message["tool_call_id"] == "allowed", results))["is_error"]
            @test count(message -> get(message, "role", "") == "system", agent.messages) == 1
            @test !any(message -> haskey(message, "toolsAdded") || haskey(message, "toolsRemoved"), agent.messages)
        finally
            close(executor)
            X.uninstall!(id)
        end
    end
end

@testset "removing the system context does not change executor permissions" begin
    mktempdir() do dir
        provider = ContextToolCases.provider()
        id = "context-tool-executor-no-system"
        @test X.install!(id, provider, [Write(dir)])
        executor = X.Executor(myid())
        try
            registry = E.Registry()
            E.register!(registry, :fixture, E.Plugin(; hooks=(:context_with_system => event -> (; messages=event.messages[2:end]),)))
            agent = Agent(nothing, Dict{String, J.Tool}(), Dict{String, Any}[Dict("role" => "system", "content" => "base")]; history=J.History.Memory())
            @test respond!(agent, "start"; executor, context=id, on_agent_event=E.listen(E.snapshot(registry))).value == "done"
            @test all(request -> isempty(request.names), provider.requests)
            @test read(joinpath(dir, "written"), String) == "ok"
            @test first(agent.messages)["content"] == "base"
        finally
            close(executor)
            X.uninstall!(id)
        end
    end
end

end
