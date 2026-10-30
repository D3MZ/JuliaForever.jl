module ExtensionCases

using Test, JuliaForever, JSON3
const E = JuliaForever.Extensions

mktempdir() do dir
    mkpath(joinpath(dir, "JuliaForever"))
    cp(joinpath(@__DIR__, "..", "Project.toml"), joinpath(dir, "JuliaForever", "Project.toml"))
    cp(joinpath(@__DIR__, "..", "src"), joinpath(dir, "JuliaForever", "src"))
    cp(joinpath(@__DIR__, "fixtures", "GreetingPlugin"), joinpath(dir, "GreetingPlugin"))
    pushfirst!(LOAD_PATH, dir)
    try
        @eval using GreetingPlugin
    finally
        popfirst!(LOAD_PATH)
    end
end

mutable struct Provider
    replies::Vector{Any}
    requests::Vector{Any}
end

function JuliaForever.complete(provider::Provider, messages, tools)
    push!(provider.requests, (; messages=deepcopy(messages), tools=Dict(name => JuliaForever.definition(tool) for (name, tool) in tools)))
    popfirst!(provider.replies)
end

struct Broken end
E.tools(::Broken) = (Write(pwd()),)
E.hooks(::Broken) = error("failed while building plugin")

function provider()
    call = Dict("id" => "one", "type" => "function", "function" => Dict("name" => "greet", "arguments" => JSON3.write((; name="Ada"))))
    Provider([Dict("role" => "assistant", "content" => nothing, "tool_calls" => [call]), Dict("role" => "assistant", "content" => "done")], [])
end

@testset "extension registry" begin
    registry = E.Registry()
    builtins = E.Plugin(; tools=(Read(pwd()),))
    @test E.register!(registry, :builtins, builtins)
    @test E.register!(registry, :greeting, GreetingPlugin.Plugin(Symbol[]))
    initial = E.snapshot(registry)
    @test JuliaForever.name.(E.tools(initial)) == ["read", "greet"]

    duplicate_id = E.register!(registry, :greeting, E.Plugin())
    @test duplicate_id isa E.Rejected
    @test duplicate_id.reason == :duplicate_plugin
    @test duplicate_id.name == "greeting"
    duplicate_tool = E.register!(registry, :collision, E.Plugin(; tools=(Write(pwd()), Read(pwd()))))
    @test duplicate_tool isa E.Rejected
    @test duplicate_tool.reason == :duplicate_tool
    @test duplicate_tool.name == "read"
    repeated_tool = E.register!(registry, :repeated, E.Plugin(; tools=(Write(pwd()), Write(pwd()))))
    @test repeated_tool isa E.Rejected
    @test repeated_tool.reason == :duplicate_tool
    @test repeated_tool.name == "write"
    @test JuliaForever.name.(E.tools(E.snapshot(registry))) == ["read", "greet"]
    @test_throws ErrorException E.register!(registry, :broken, Broken())
    @test JuliaForever.name.(E.tools(E.snapshot(registry))) == ["read", "greet"]
    @test E.register!(registry, :broken, E.Plugin())
    @test E.remove!(registry, :broken)
    @test !E.remove!(registry, :unknown)
    @test E.remove!(registry, :greeting)
    @test JuliaForever.name.(E.tools(E.snapshot(registry))) == ["read"]
    @test JuliaForever.name.(E.tools(initial)) == ["read", "greet"]
    @test E.register!(registry, :greeting, GreetingPlugin.Plugin(Symbol[]))
end

@testset "hook ordering, isolation, failures and removal" begin
    registry = E.Registry()
    observed = String[]
    first = E.Plugin(; hooks=(:message_end => (event -> (event.message["content"] = "changed"; push!(observed, "first"))), :message_end => (event -> (push!(observed, "failure"); error("broken hook")))))
    second = E.Plugin(; hooks=(:message_end => (event -> push!(observed, event.message["content"])),))
    @test E.register!(registry, :first, first)
    @test E.register!(registry, :second, second)
    snapshot = E.snapshot(registry)
    callback = E.listen(snapshot; on_event=event -> push!(observed, "host " * event.message["content"]))
    callback((; type=:message_end, message=Dict("content" => "original")))
    @test observed == ["first", "failure", "original", "host original"]
    failures = E.failures(callback)
    @test length(failures) == 1
    @test failures[1].plugin == :first
    @test failures[1].event == :message_end
    @test sprint(showerror, failures[1].exception) == "broken hook"
    empty!(failures)
    @test length(E.failures(callback)) == 1
    @test E.remove!(registry, :first)
    @test E.register!(registry, :first, first)
    empty!(observed)
    E.listen(E.snapshot(registry))((; type=:message_end, message=Dict("content" => "original")))
    @test observed == ["original", "first", "failure"]
    empty!(observed)
    callback((; type=:message_end, message=Dict("content" => "old snapshot")))
    @test observed == ["first", "failure", "old snapshot", "host old snapshot"]
    failing_host = E.listen(snapshot; on_event=event -> error("host failed"))
    @test_throws ErrorException failing_host((; type=:message_end, message=Dict("content" => "host")))
end

@testset "native plugin with Agent" begin
    for history in (nothing, JuliaForever.History.Memory())
        events = Symbol[]
        registry = E.Registry()
        @test E.register!(registry, :greeting, GreetingPlugin.Plugin(events))
        @test E.register!(registry, :failing, E.Plugin(; hooks=(:tool_execution_end => (event -> error("hook failed")),)))
        @test E.register!(registry, :after, E.Plugin(; hooks=(:tool_execution_end => (event -> push!(events, :after_failure)),)))
        snapshot = E.snapshot(registry)
        listener = E.listen(snapshot)
        backend = provider()
        agent = Agent(backend, snapshot; history)
        if isnothing(history)
            messages = Dict{String, Any}[Dict("role" => "system", "content" => "context")]
            with_context = Agent(provider(), snapshot, messages)
            @test with_context.messages === messages
            @test haskey(with_context.tools, "greet")
        end
        @test respond!(agent, "greet Ada"; on_agent_event=listener) == "done"
        @test events == [:agent_start, :tool_execution_end, :after_failure, :agent_end]
        @test length(E.failures(listener)) == 1
        @test E.failures(listener)[1].plugin == :failing
        @test backend.requests[1].tools["greet"]["function"]["description"] == "Greet a person"
        @test backend.requests[1].tools["greet"]["function"]["parameters"]["required"] == ["name"]
        @test backend.requests[2].messages[end]["content"] == "Hello, Ada!"
        if !isnothing(history)
            before = copy(events)
            restored = Agent(provider(), snapshot; history)
            @test restored isa Agent
            @test events == before
        end
        @test E.remove!(registry, :greeting)
        @test !haskey(Agent(provider(), E.snapshot(registry)).tools, "greet")
        @test haskey(agent.tools, "greet")
    end
end

@testset "concurrent registration is atomic" begin
    registry = E.Registry()
    results = fetch.([Threads.@spawn E.register!(registry, Symbol("plugin", i), E.Plugin(; tools=(GreetingPlugin.Greet(),))) for i in 1:8])
    @test count(==(true), results) == 1
    @test count(result -> result isa E.Rejected && result.reason == :duplicate_tool, results) == 7
    @test JuliaForever.name.(E.tools(E.snapshot(registry))) == ["greet"]
end

end
