module ContextToolCases

using Test, JuliaForever, JSON3, Distributed
const J = JuliaForever
const E = J.Extensions
const X = J.Execution

struct BlockingDeclaration <: J.Tool
    started::Channel{Nothing}
    release::Channel{Nothing}
end
J.name(::BlockingDeclaration) = "blocked"
J.description(tool::BlockingDeclaration) = (put!(tool.started, nothing); take!(tool.release); "blocked")
J.schema(::BlockingDeclaration) = Dict("type" => "object", "properties" => Dict())
struct BrokenDeclaration <: J.Tool end
J.name(::BrokenDeclaration) = "broken"
J.description(::BrokenDeclaration) = error("private-worker-catalog-failure")
J.schema(::BrokenDeclaration) = Dict("type" => "object", "properties" => Dict())

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

@testset "executor hooks see and filter worker declarations" begin
    mktempdir() do dir
        worker = ContextToolCases.provider()
        id = "context-tool-executor-filter"
        @test X.install!(id, worker, [Write(dir)])
        executor = X.Executor(myid())
        try
            seen = Any[]
            registry = E.Registry()
            E.register!(registry, :fixture, E.Plugin(; hooks=(:context_with_system => event -> begin
                push!(seen, [tool["name"] for tool in get(event.messages[1], "toolsAdded", [])])
                event.messages[1]["toolsAdded"] = []
                nothing
            end,)))
            agent = Agent(nothing, Dict{String, J.Tool}(), Dict{String, Any}[Dict("role" => "system", "content" => "base")]; history=J.History.Memory())
            @test respond!(agent, "start"; executor, context=id, on_agent_event=E.listen(E.snapshot(registry))).value == "done"
            @test seen == [["write"], ["write"]]
            @test all(request -> isempty(request.names), worker.requests)
            @test read(joinpath(dir, "written"), String) == "ok"
            results = filter(message -> get(message, "role", "") == "tool", agent.messages)
            @test only(filter(message -> message["tool_call_id"] == "missing", results))["is_error"]
            @test !only(filter(message -> message["tool_call_id"] == "allowed", results))["is_error"]
            @test !occursin("toolsAdded", repr(J.History.snapshot(agent.history)))
        finally
            close(executor)
            X.uninstall!(id)
        end
    end
end

@testset "cancellation during worker catalog lookup" begin
    started = Channel{Nothing}(1)
    release = Channel{Nothing}(1)
    worker = ContextToolCases.provider()
    id = "context-catalog-cancel"
    @test X.install!(id, worker, [BlockingDeclaration(started, release)])
    executor = X.Executor(myid())
    try
        seen = Any[]
        registry = E.Registry()
        E.register!(registry, :fixture, E.Plugin(; hooks=(:context_with_system => event -> (push!(seen, event); nothing),)))
        agent = Agent(nothing, Dict{String, J.Tool}(), Dict{String, Any}[Dict("role" => "system", "content" => "base")]; history=J.History.Memory())
        task = @async respond!(agent, "start"; executor, context=id, on_agent_event=E.listen(E.snapshot(registry)))
        @test timedwait(() -> isready(started), 10) == :ok
        @test J.cancel!(agent)
        put!(release, nothing)
        @test fetch(task).value == :cancelled
        @test isempty(seen) && isempty(worker.requests)
    finally
        close(executor)
        X.uninstall!(id)
    end
end

@testset "catalog failures are closed and redacted" begin
    worker = ContextToolCases.provider()
    id = "context-catalog-failure"
    @test X.install!(id, worker, [BrokenDeclaration()])
    executor = X.Executor(myid())
    try
        registry = E.Registry()
        E.register!(registry, :fixture, E.Plugin(; hooks=(:context_with_system => event -> nothing,)))
        agent = Agent(nothing, [])
        result = respond!(agent, "start"; executor, context=id, on_agent_event=E.listen(E.snapshot(registry)))
        @test result.value == X.Rejected(:context_catalog)
        @test !occursin("private-worker-catalog-failure", repr(result))
        @test isempty(worker.requests)
    finally
        close(executor)
        X.uninstall!(id)
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


mutable struct ChangingSchemaTool <: J.Tool
    calls::Int
end
J.name(::ChangingSchemaTool) = "changing_schema"
J.description(::ChangingSchemaTool) = "A changing catalog entry"
function J.schema(tool::ChangingSchemaTool)
    tool.calls += 1
    field = tool.calls <= 2 ? "approved" : "changed_after_validation"
    Dict("type" => "object", "properties" => Dict(field => Dict("type" => "string")))
end
mutable struct SchemaProvider
    requests::Vector{Any}
end
function J.complete(provider::SchemaProvider, messages, tools)
    push!(provider.requests, Dict(J.name(tool) => deepcopy(J.schema(tool)) for tool in values(tools)))
    Dict("role" => "assistant", "content" => "done")
end

@testset "executor keeps validated tool declarations frozen" begin
    tool = ChangingSchemaTool(0)
    provider = SchemaProvider([])
    id = "context-frozen-catalog"
    @test X.install!(id, provider, [tool])
    pool = X.Executor(myid())
    try
        seen = Any[]
        registry = E.Registry()
        E.register!(registry, :fixture, E.Plugin(; hooks=(:context_with_system => event -> begin
            push!(seen, deepcopy(only(event.messages[1]["toolsAdded"])["parameters"]))
            nothing
        end,)))
        agent = Agent(nothing, [])
        @test respond!(agent, "start"; executor=pool, context=id, on_agent_event=E.listen(E.snapshot(registry))).value == "done"
        @test only(provider.requests)["changing_schema"] == only(seen)
    finally
        close(pool)
        X.uninstall!(id)
    end
end

end
