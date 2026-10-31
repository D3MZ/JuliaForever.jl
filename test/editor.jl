using Test, JSON3

@testset "terminal editor" begin
    root = dirname(@__DIR__)
    cases = joinpath(@__DIR__, "editor_cases.json")
    if haskey(ENV, "PI_SOURCE")
        source = ENV["PI_SOURCE"]
        @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
        expected = JSON3.read(read(cases, String))
        actual = JSON3.read(read(`node $(joinpath(@__DIR__, "editor_pi.mjs")) $source`, String))
        @test actual.inputs == expected.inputs
        @test actual.submitted == expected.submitted
    end
    python = Sys.which("python3")
    if Sys.isunix() && !isnothing(python)
        julia = first(Base.julia_cmd().exec)
        process = run(ignorestatus(`$python $(joinpath(@__DIR__, "editor_pty.py")) $root $cases $julia`))
        @test success(process)

    else
        @test_skip false
    end
end
