module ManualTextHistoryTests
using Test, JuliaForever

@testset "manual compaction survives mode changes" begin
    python = Sys.which("python3")
    if haskey(ENV, "PI_SOURCE") && !isnothing(python)
        project = dirname(@__DIR__)
        cmd = `$python $(joinpath(@__DIR__, "manual_text_history.py")) $project $(first(Base.julia_cmd().exec)) $(ENV["PI_SOURCE"])`
        @test success(run(ignorestatus(cmd)))
    else
        @test_skip false
    end
end

end
