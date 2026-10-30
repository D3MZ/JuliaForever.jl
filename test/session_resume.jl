using Test, JuliaForever
import JuliaForever.History as ResumeHistory
import JuliaForever.SessionCatalog as ResumeCatalog

struct ResumeProvider end
JuliaForever.complete(::ResumeProvider, messages, tools; kwargs...) = Dict{String, Any}("role" => "assistant", "content" => "ok")

mutable struct ResumeStore <: ResumeHistory.Store
    memory::ResumeHistory.Memory
    closes::Int
    snapshot_failure::Any
    close_failure::Any
end
ResumeStore() = ResumeStore(ResumeHistory.Memory(), 0, nothing, nothing)
function ResumeHistory.snapshot(store::ResumeStore)
    isnothing(store.snapshot_failure) || throw(store.snapshot_failure)
    ResumeHistory.snapshot(store.memory)
end
Base.append!(store::ResumeStore, revision::Integer, batch::Vector) = append!(store.memory, revision, batch)
function Base.close(store::ResumeStore)
    store.closes += 1
    isnothing(store.close_failure) || throw(store.close_failure)
    nothing
end
resumetree() = ResumeHistory.Tree(ResumeStore())

mutable struct ResumeDatabase
    closes::Int
end
ResumeHistory.snapshot(::ResumeHistory.SQLite{ResumeDatabase}) = throw(ArgumentError("snapshot failed"))
Base.close(store::ResumeHistory.SQLite{ResumeDatabase}) = (store.db.closes += 1; nothing)

@testset "session resume" begin
@testset "resume session ownership" begin
    terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), ["secret"])
    first = resumetree()
    second = resumetree()
    third = resumetree()
    agent = Agent(ResumeProvider(), []; history=first)
    Agent(ResumeProvider(), []; history=second)
    Agent(ResumeProvider(), []; history=third)
    cancelled = JuliaForever.resume!(terminal, agent, first, ResumeCatalog.Cancelled())
    @test cancelled == (agent, first, 0)
    @test first.store.closes == 0

    restored, history, status = JuliaForever.resume!(terminal, agent, first, second)
    @test status == 0 && restored.history === second && history === second
    @test first.store.closes == 1 && second.store.closes == 0
    restored, history, status = JuliaForever.resume!(terminal, restored, second, third)
    @test status == 0 && restored.history === third && history === third
    @test second.store.closes == 1 && third.store.closes == 0
    close(history)
    @test third.store.closes == 1
end

@testset "resume session failure cleanup" begin
    terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), ["synthetic\tsecret"])
    current = resumetree()
    agent = Agent(ResumeProvider(), []; history=current)
    unexpected = resumetree()
    Agent(ResumeProvider(), []; history=unexpected)
    unexpected.store.snapshot_failure = ArgumentError("unexpected")
    @test_throws ArgumentError JuliaForever.resume!(terminal, agent, current, unexpected)
    @test unexpected.store.closes == 1
    @test current.store.closes == 0

    unreadable = resumetree()
    Agent(ResumeProvider(), []; history=unreadable)
    unreadable.store.snapshot_failure = Base.IOError("cannot read " * repr("synthetic\tsecret"), Int32(-13))
    previous, history, status = JuliaForever.resume!(terminal, agent, current, unreadable)
    @test previous === agent && history === current && status == 1
    @test unreadable.store.closes == 1 && current.store.closes == 0
    text = String(take!(terminal.diagnostics))
    @test occursin("[redacted]", text)
    @test !occursin("synthetic\\tsecret", text)
    @test !occursin("synthetic\tsecret", text)
    close(current)
    @test current.store.closes == 1
end

@testset "picker closes a failed opened history" begin
    database = ResumeDatabase(0)
    store = ResumeHistory.SQLite(database, ReentrantLock(), ResumeHistory.Open())
    @test_throws ArgumentError ResumeCatalog.wrap(store)
    @test database.closes == 1
end

@testset "resume owner closes on replacement failure" begin
    first = resumetree()
    second = resumetree()
    agent = Agent(ResumeProvider(), []; history=first)
    Agent(ResumeProvider(), []; history=second)
    terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), String[])
    first.store.close_failure = ArgumentError("close failed")
    @test_throws ArgumentError JuliaForever.resume!(terminal, agent, first, second)
    @test first.store.closes == 1
    @test second.store.closes == 1
end

@testset "resume picker redacts without changing saved content" begin
    mktempdir() do root
        key = "synthetic\tsecret"
        id = repeat("a", 32)
        first = ResumeCatalog.new(root, pwd())
        agent = Agent(ResumeProvider(), []; history=first)
        @test respond!(agent, "before " * key * " after") == "ok"
        path = ResumeCatalog.path(first)
        close(first)
        renamed = joinpath(root, ResumeCatalog.filename(pwd(), id))
        mv(path, renamed)

        current = resumetree()
        active = Agent(ResumeProvider(), []; history=current)
        terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), [key, id])
        unchanged, unchanged_history, status = JuliaForever.resume!(terminal, active, current, IOBuffer("q\n"), root)
        @test status == 0 && unchanged === active && unchanged_history === current
        @test current.store.closes == 0
        take!(terminal.diagnostics)
        restored, selected, status = JuliaForever.resume!(terminal, active, current, IOBuffer("1\n"), root)
        output = String(take!(terminal.diagnostics))
        @test status == 0 && selected isa ResumeHistory.Tree
        @test occursin("before [redacted] after", output)
        @test !occursin(key, output) && !occursin(id, output)
        @test restored.messages[1]["content"] == "before " * key * " after"
        @test current.store.closes == 1
        close(selected)
        @test ResumeHistory.snapshot(selected) == ResumeHistory.Rejected(:closed)
    end
end

@testset "resumed fault reports a redacted history path" begin
    mktempdir() do root
        key = "synthetic\tsecret"
        directory = joinpath(root, "sessions-" * key)
        selected = ResumeCatalog.new(directory, pwd())
        existing = Agent(ResumeProvider(), []; history=selected)
        JuliaForever.transition!(revision -> JuliaForever.Conversation.Input(revision, "blocked"), existing)
        JuliaForever.transition!(revision -> JuliaForever.Conversation.Advance(revision), existing)
        path = ResumeCatalog.path(selected)
        close(selected)
        selected = ResumeHistory.Tree(open(ResumeHistory.SQLite, path; create=false))
        current = resumetree()
        active = Agent(ResumeProvider(), []; history=current)
        terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), [key])
        unchanged, unchanged_history, status = JuliaForever.resume!(terminal, active, current, selected)
        output = String(take!(terminal.diagnostics))
        @test status == 1 && unchanged === active && unchanged_history === current
        @test occursin("uncertain pending effect", output)
        @test occursin("[redacted]", output) && !occursin(key, output)
        @test ResumeHistory.snapshot(selected) == ResumeHistory.Rejected(:closed)
        @test current.store.closes == 0
        close(current)
    end
end

@testset "resume picker filesystem failure is redacted" begin
    Sys.isunix() && mktempdir() do root
        key = "synthetic\tsecret"
        directory = joinpath(root, "sessions-" * key)
        mkpath(directory)
        current = resumetree()
        agent = Agent(ResumeProvider(), []; history=current)
        terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), [key])
        chmod(directory, 0o000)
        try
            previous, history, status = JuliaForever.resume!(terminal, agent, current, IOBuffer("q\n"), directory)
            output = String(take!(terminal.diagnostics))
            @test previous === agent && history === current && status == 1
            @test occursin("[redacted]", output)
            @test !occursin(key, output) && !occursin("synthetic\\tsecret", output)
            @test current.store.closes == 0
        finally
            chmod(directory, 0o700)
            close(current)
        end
    end
end
end
