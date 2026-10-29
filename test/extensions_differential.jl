@testset "Pi extension notifications and custom tool" begin
    source = ENV["PI_SOURCE"]
    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    reference = JSON3.read(read(`node $(joinpath(@__DIR__, "extensions_reference.mjs")) $source`, String), Dict{String, Any})
    E = JuliaForever.Extensions
    trace = String[]
    registry = E.Registry()
    first = E.Plugin(; tools=(ExtensionCases.GreetingPlugin.Greet(),), hooks=(:agent_start => (event -> push!(trace, "first")), :agent_start => (event -> (push!(trace, "failure"); error("broken hook")))))
    second = E.Plugin(; hooks=(:agent_start => (event -> push!(trace, "second")),))
    @test E.register!(registry, :first, first)
    @test E.register!(registry, :second, second)
    snapshot = E.snapshot(registry)
    listener = E.listen(snapshot)
    backend = ExtensionCases.provider()
    agent = Agent(backend, snapshot)
    @test respond!(agent, "greet Ada"; on_agent_event=listener) == "done"
    @test trace == reference["trace"]
    failures = [Dict("plugin" => string(failure.plugin), "event" => string(failure.event), "message" => sprint(showerror, failure.exception)) for failure in E.failures(listener)]
    @test failures == reference["errors"]
    definition = backend.requests[1].tools["greet"]["function"]
    @test definition["name"] == reference["name"]
    @test definition["description"] == reference["description"]
    @test definition["parameters"] == reference["parameters"]
    @test backend.requests[2].messages[end]["content"] == reference["result"]
end
