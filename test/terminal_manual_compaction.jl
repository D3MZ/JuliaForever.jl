module TerminalManualCompactionTests
using Test, JuliaForever

@testset "terminal manual compaction settings and instructions" begin
    python = Sys.which("python3")
    if haskey(ENV, "PI_SOURCE") && !isnothing(python)
        project = dirname(@__DIR__)
        cmd = `$python $(joinpath(@__DIR__, "terminal_manual_compaction.py")) $project $(first(Base.julia_cmd().exec)) $(ENV["PI_SOURCE"])`
        @test success(run(ignorestatus(cmd)))
    else
        @test_skip false
    end
end

@testset "interactive manual compaction" begin
    python, tmux = Sys.which("python3"), Sys.which("tmux")
    if Sys.isunix() && !isnothing(python) && !isnothing(tmux)
        project = dirname(@__DIR__)
        cmd = `$python $(joinpath(@__DIR__, "terminal_manual_live.py")) $project $(first(Base.julia_cmd().exec))`
        @test success(run(ignorestatus(cmd)))
    else
        @test_skip false
    end
end
end
