using Test, JuliaForever
import JuliaForever.History as ForkHistory
import JuliaForever.Conversation as ForkConversation
import JuliaForever.SessionCatalog as ForkCatalog

struct ForkProvider end
JuliaForever.complete(::ForkProvider, messages, tools) = Dict("role" => "assistant", "content" => "reply:" * messages[end]["content"])
struct InterruptedForkProvider end
JuliaForever.complete(::InterruptedForkProvider, messages, tools) = sqrt(-1)
forktexts(agent) = [message["content"] for message in agent.messages if message["role"] in ("user", "assistant")]

@testset "copy a session path without changing its source" begin
    store = ForkHistory.Memory()
    source = ForkHistory.Tree(store)
    provider = ForkProvider()
    agent = Agent(provider, []; history=source)
    @test name!(agent, "Project") === nothing
    @test respond!(agent, "first") == "reply:first"
    @test respond!(agent, "second") == "reply:second"
    original = ForkHistory.snapshot(source)
    inputs = [entry for entry in ForkHistory.entries(source) if ForkHistory.decode_event(only(entry.batch)) isa ForkConversation.Input]
    parent = inputs[2].parent
    path = ForkCatalog.branchpath(source, parent)
    target = ForkCatalog.duplicate(ForkHistory.Tree(ForkHistory.Memory()), path, ForkCatalog.Path())
    @test ForkCatalog.sessionname(target) == "Project"
    @test forktexts(Agent(provider, []; history=target)) == ["first", "reply:first"]
    @test respond!(Agent(provider, []; history=target), "replacement") == "reply:replacement"
    after = ForkHistory.snapshot(source)
    @test after.revision == original.revision
    @test after.batches == original.batches
    @test forktexts(Agent(provider, []; history=source)) == ["first", "reply:first", "second", "reply:second"]

    @test ForkHistory.branch!(source, parent) == parent
    @test respond!(Agent(provider, []; history=source), "alternative") == "reply:alternative"
    all = ForkCatalog.duplicate(ForkHistory.Tree(ForkHistory.Memory()), ForkCatalog.allpaths(source), ForkCatalog.Whole())
    @test ForkCatalog.sessionname(all) == "Project"
    @test length(ForkHistory.entries(all)) == length(ForkHistory.entries(source))
    @test forktexts(Agent(provider, []; history=all)) == ["first", "reply:first", "alternative", "reply:alternative"]
    @test ForkHistory.branch!(all, original.revision) == original.revision
    @test forktexts(Agent(provider, []; history=all)) == ["first", "reply:first", "second", "reply:second"]
end

@testset "forks reject stale and uncertain histories" begin
    store = ForkHistory.Memory()
    source = ForkHistory.Tree(store)
    provider = ForkProvider()
    agent = Agent(provider, []; history=source)
    stale = ForkHistory.Tree(store)
    @test respond!(agent, "first") == "reply:first"
    @test ForkCatalog.branchpath(stale, 1) == ForkHistory.Rejected(:revision)
    @test ForkCatalog.allpaths(stale) == ForkHistory.Rejected(:revision)
    @test ForkCatalog.branchpath(source, 9999) == ForkHistory.Rejected(:missing_branch)

    interrupted = ForkHistory.Tree(ForkHistory.Memory())
    failing = Agent(InterruptedForkProvider(), []; history=interrupted)
    @test_throws DomainError respond!(failing, "interrupted")
    @test ForkCatalog.branchpath(interrupted, 1) == ForkHistory.Rejected(:uncertain_effect)
    @test ForkCatalog.allpaths(interrupted) == ForkHistory.Rejected(:uncertain_effect)
end

@testset "fork lookup across projects" begin
    mktempdir() do root
        directory = joinpath(root, "sessions")
        here = joinpath(root, "here")
        other = joinpath(root, "other")
        mkpath.((here, other))
        source = ForkCatalog.new(directory, other)
        @test respond!(Agent(ForkProvider(), []; history=source), "foreign") == "reply:foreign"
        path = ForkCatalog.path(source)
        close(source)
        before = read(path)
        id = only(ForkCatalog.list(directory, other)).id
        fork = ForkCatalog.choose(ForkCatalog.Fork(id), directory, here, IOBuffer(), IOBuffer())
        @test fork isa ForkHistory.Tree
        @test forktexts(Agent(ForkProvider(), []; history=fork)) == ["foreign", "reply:foreign"]
        @test startswith(basename(ForkCatalog.path(fork)), ForkCatalog.project(here))
        @test read(path) == before
        close(fork)

        cp(path, joinpath(directory, ForkCatalog.filename(other, repeat("a", 32))))
        cp(path, joinpath(directory, ForkCatalog.filename(other, repeat("a", 31) * "b")))
        files = Set(readdir(directory))
        @test ForkCatalog.choose(ForkCatalog.Fork(repeat("a", 8)), directory, here, IOBuffer(), IOBuffer()) isa ForkCatalog.Invalid
        @test Set(readdir(directory)) == files
    end
end
