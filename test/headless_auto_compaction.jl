module HeadlessAutoCompactionTests

using Test, JuliaForever, JSON3

@testset "JSON and RPC automatic compaction" begin
    python = Sys.which("python3")
    if haskey(ENV, "PI_SOURCE") && !isnothing(python)
        project = dirname(@__DIR__)
        cmd = `$python $(joinpath(@__DIR__, "headless_auto_compaction.py")) $project $(first(Base.julia_cmd().exec)) $(ENV["PI_SOURCE"])`
        @test success(run(ignorestatus(cmd)))
    else
        @test_skip false
    end
end

end
