using Test

@testset "fullscreen terminal against Pi" begin
    python = Sys.which("python3")
    if Sys.isunix() && !isnothing(python)
        source = ENV["PI_SOURCE"]
        @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
        julia = first(Base.julia_cmd().exec)
        @test success(`$python $(joinpath(@__DIR__, "fullscreen_pty.py")) $julia $(dirname(@__DIR__))`)
        if !isnothing(Sys.which("tmux"))
            @test success(`$python $(joinpath(@__DIR__, "fullscreen_live.py")) $(dirname(@__DIR__)) $julia`)
        end
    else
        @test_skip false
    end
end
