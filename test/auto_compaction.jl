@testset "usage-backed automatic compaction" begin
    settings = JuliaForever.AutoCompaction(100, 20)
    disabled = JuliaForever.AutoCompaction(100, 20; enabled=false)
    @test settings isa JuliaForever.AutoCompaction && disabled isa JuliaForever.AutoCompaction
    @test typeof(settings) !== typeof(disabled)
    @test (settings.context_window, settings.reserve_tokens) == (disabled.context_window, disabled.reserve_tokens)
    provider = CompactProvider(nothing, Any[])
    agent = compactagent(provider; history=CompactHistory.Memory())
    calls = Ref(0)
    summarize = _ -> (calls[] += 1; "automatic checkpoint")
    usage(n) = JuliaForever.Usage(n, 0, 0, 0, 0, n, nothing)
    @test JuliaForever.autocompact!(agent, usage(80), settings, summarize) === nothing
    @test calls[] == 0
    @test JuliaForever.autocompact!(agent, usage(81), JuliaForever.AutoCompaction(100, 20; enabled=false), summarize) === nothing
    @test JuliaForever.autocompact!(agent, usage(81), settings, summarize) == "automatic checkpoint"
    @test calls[] == 1
    @test JuliaForever.autocompact!(agent, nothing, settings, summarize) === nothing
    @test JuliaForever.autocompact!(agent, usage(0), JuliaForever.AutoCompaction(10, 20), summarize) === nothing
end
