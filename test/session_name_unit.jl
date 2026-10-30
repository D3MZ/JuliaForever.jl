using Test, JuliaForever
import JuliaForever.History as NameHistory
import JuliaForever.SessionCatalog as NameCatalog

@testset "session names survive branches without creating an empty file" begin
    mktempdir() do root
        history = NameCatalog.new(joinpath(root, "sessions"), root)
        agent = Agent(nothing, []; history)
        @test name!(agent, "  First\nName  ") === nothing
        @test NameCatalog.sessionname(history) == "First Name"
        @test !isfile(NameCatalog.path(history))
        @test name!(agent, "Second") === nothing
        @test NameHistory.branch!(history, 1) == 1
        @test NameCatalog.sessionname(history) == "Second"
        branched = Agent(nothing, []; history)
        @test name!(branched, "Third") === nothing
        @test NameCatalog.sessionname(history) == "Third"
        @test !isfile(NameCatalog.path(history))
        @test name!(branched, " ") === nothing
        @test NameCatalog.sessionname(history) === nothing
        close(history)
    end
end

@testset "session naming respects stale revisions" begin
    history = NameHistory.Memory()
    first = Agent(nothing, []; history)
    stale = Agent(nothing, []; history)
    @test name!(first, "First") === nothing
    @test name!(stale, "Stale") == NameHistory.Rejected(:revision)
    @test NameCatalog.sessionname(history) == "First"
    @test JuliaForever.terminalcommand("/namefoo") === nothing
end
