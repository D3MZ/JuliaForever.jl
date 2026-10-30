using Test

@testset "live skill reload" begin
    python = Sys.which("python3")
    if Sys.isunix() && !isnothing(python)
        root = dirname(@__DIR__)
        julia = first(Base.julia_cmd().exec)
        cmd = addenv(`$python $(joinpath(@__DIR__, "skill_reload_live.py")) $root $julia`, "JULIA_DEPOT_PATH" => join(DEPOT_PATH, ':'))
        process = run(ignorestatus(cmd))
        @test success(process)
    else
        @test_skip false
    end
end
