using Test, JuliaForever
import JuliaForever.History as NameHistory
import JuliaForever.SessionCatalog as NameCatalog

@testset "empty session names and branches" begin
    mktempdir() do root
        history = NameCatalog.new(root, pwd())
        agent = Agent(nothing, []; history)
        @test name!(agent, "First") === nothing
        @test name!(agent, "Second") === nothing
        @test NameHistory.branch!(history, 1) == 1
        agent = Agent(nothing, []; history)
        @test name!(agent, "Third") === nothing
        @test !isfile(NameCatalog.path(history))
        @test name!(agent, " ") === nothing
        @test NameCatalog.sessionname(history) === nothing
        @test !isfile(NameCatalog.path(history))
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
