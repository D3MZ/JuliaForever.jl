using Test

@testset "live skill reload" begin
    python = Sys.which("python3")
    if Sys.isunix() && !isnothing(python)
        root = dirname(@__DIR__)
        julia = first(Base.julia_cmd().exec)
        process = run(ignorestatus(`$python $(joinpath(@__DIR__, "skill_reload_live.py")) $root $julia`))
        @test success(process)
    else
        @test_skip false
    end
end
