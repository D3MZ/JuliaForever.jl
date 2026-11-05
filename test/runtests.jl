using Test

include(joinpath(@__DIR__, "..", "src", "HotReload.jl"))
const HR = HotReload

function fixture(name; version="one", reload_hook=false)
    hook = reload_hook ?
        "on_reload!(state) = (push!(get!(state, :events, String[]), \"reload\"); nothing)" : ""
    """
    const VERSION = "$version"
    tool_schemas() = Any[Dict("type" => "function", "name" => "$name")]
    run_tool(session, name, args, state) = nothing
    on_key!(menu, event, state) = false
    on_frame!(menu, state) = nothing
    footer(menu, state) = ""
    shutdown!(state) = (push!(get!(state, :events, String[]), "shutdown"); nothing)
    $hook
    """
end

function new_manager()
    HR.Manager("", Main, ReentrantLock(), nothing, Dict{String,Dict{Symbol,Any}}(),
               "", Set{Tuple{String,Symbol}}(), Threads.Atomic{Bool}(false), nothing)
end

@testset "Live feature replacement lifecycle" begin
    manager = new_manager()
    first_source = fixture("first")
    second_source = fixture("second"; reload_hook=true)
    initial = HR.reload!(manager, ["a.jl" => first_source, "b.jl" => second_source])
    a_state = manager.states["a.jl"]
    b_state = manager.states["b.jl"]
    a_state[:persistent] = 42

    same = HR.reload!(manager, ["a.jl" => first_source, "b.jl" => second_source])
    @test same.sources[1].second === initial.sources[1].second
    @test same.sources[2].second === initial.sources[2].second
    @test !haskey(a_state, :events)
    @test !haskey(b_state, :events)

    changed_second = fixture("second"; version="two", reload_hook=true)
    replaced = HR.reload!(manager, ["a.jl" => first_source, "b.jl" => changed_second])
    @test replaced.sources[1].second === initial.sources[1].second
    @test replaced.sources[2].second !== initial.sources[2].second
    @test b_state[:events] == ["reload"]
    @test !haskey(a_state, :events)
    @test manager.states["b.jl"] === b_state

    changed_first = fixture("first"; version="two")
    HR.reload!(manager, ["a.jl" => changed_first, "b.jl" => changed_second])
    @test a_state[:events] == ["shutdown"]
    @test manager.states["a.jl"] === a_state
    @test a_state[:persistent] == 42
    @test b_state[:events] == ["reload"]

    before_invalid = manager.generation
    @test_throws ErrorException HR.reload!(manager,
        ["a.jl" => fixture("duplicate"), "b.jl" => fixture("duplicate")])
    @test manager.generation === before_invalid
    @test a_state[:events] == ["shutdown"]
    @test b_state[:events] == ["reload"]

    HR.reload!(manager, ["a.jl" => changed_first])
    @test b_state[:events] == ["reload", "shutdown"]
    @test !haskey(manager.states, "b.jl")
    @test haskey(manager.states, "a.jl")
end
