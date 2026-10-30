@testset "Pi usage threshold" begin
    pi = JSON3.read(read(`node $(joinpath(@__DIR__, "auto_compaction_pi.mjs")) $(ENV["PI_SOURCE"])`, String))
    usage(n) = JuliaForever.Usage(n, 0, 0, 0, 0, n, nothing)
    decisions = map(((80, true), (81, true), (81, false))) do (n, enabled)
        agent = compactagent(CompactProvider(nothing, Any[]); history=CompactHistory.Memory())
        JuliaForever.autocompact!(agent, usage(n), JuliaForever.AutoCompaction(100, 20; enabled), _ -> "checkpoint") !== nothing
    end
    @test collect(decisions) == pi.decisions
    @test JuliaForever.contexttokens(JuliaForever.Usage(1, 2, 3, 4, 0, 0, nothing)) == pi.tokens
end
