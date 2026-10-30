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
    provider = OpenAI("http://fixture", "selected-model", "synthetic")
    mode = CodeMode(JuliaForever.Tool[])
    agent = Agent(provider, [mode]; history=first)
    Agent(ResumeProvider(), []; history=second)
    Agent(ResumeProvider(), []; history=third)
    cancelled = JuliaForever.resume!(terminal, agent, first, ResumeCatalog.Cancelled())
    @test cancelled == (agent, first, 0)
    @test first.store.closes == 0
    @test JuliaForever.resume!(terminal, agent, first, first) == (agent, first, 0)
    @test first.store.closes == 0

    restored, history, status = JuliaForever.resume!(terminal, agent, first, second)
    @test status == 0 && restored.history === second && history === second
    @test restored.provider === provider && restored.tools["codemode"] === mode
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

@testset "interactive resume transfers the active history" begin
    mktempdir() do root
        saved = ResumeCatalog.new(root, pwd())
        saved_agent = Agent(ResumeProvider(), []; history=saved)
        @test respond!(saved_agent, "saved") == "ok"
        close(saved)
        current = resumetree()
        active = Agent(ResumeProvider(), []; history=current)
        store = Ref{Union{Nothing, ResumeHistory.Store}}(current)
        terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), String[])
        status = JuliaForever.interact!(terminal, active, nothing, IOBuffer("/resume\n1\n/exit\n"), IOBuffer(), store, root)
        @test status == 0
        @test current.store.closes == 1
        @test store[] isa ResumeHistory.Tree && store[] !== current
        selected = store[]
        @test ResumeHistory.snapshot(selected) isa ResumeHistory.Snapshot
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

mutable struct ResumeCountingProvider
    calls::Int
end
function JuliaForever.complete(provider::ResumeCountingProvider, messages, tools; kwargs...)
    provider.calls += 1
    Dict{String, Any}("role" => "assistant", "content" => "ok")
end

struct ResumeQueueInput <: IO
    input::IOBuffer
    agent::Agent
end
Base.eof(input::ResumeQueueInput) = eof(input.input)
function Base.readline(input::ResumeQueueInput; keep=false)
    steer!(input.agent, "late synthetic-key")
    readline(input.input; keep)
end

mutable struct ResumeRaceStore <: ResumeHistory.Store
    memory::ResumeHistory.Memory
    hook::Function
    closes::Int
end
ResumeHistory.snapshot(store::ResumeRaceStore) = (store.hook(); ResumeHistory.snapshot(store.memory))
Base.append!(store::ResumeRaceStore, revision::Integer, batch::Vector) = append!(store.memory, revision, batch)
Base.close(store::ResumeRaceStore) = (store.closes += 1; nothing)

@testset "resume preserves active pending input and faults" begin
    mktempdir() do root
        target_dir = joinpath(root, "target")
        target = ResumeCatalog.new(target_dir, pwd())
        @test respond!(Agent(ResumeProvider(), []; history=target), "saved") == "ok"
        close(target)
        for kind in (:ephemeral, :durable)
            source = kind == :ephemeral ? nothing : ResumeCatalog.new(joinpath(root, "source"), pwd())
            provider = ResumeCountingProvider(0)
            agent = Agent(provider, []; history=source)
            steer!(agent, "steer synthetic-key")
            followup!(agent, "follow synthetic-key")
            input = IOBuffer("1\n")
            terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), ["synthetic-key"])
            previous, owner, status = JuliaForever.resume!(terminal, agent, source, input, target_dir)
            @test status == 1 && previous === agent && owner === source
            @test position(input) == 0 && provider.calls == 0
            @test agent.state.steering == ["steer synthetic-key"] && agent.state.followups == ["follow synthetic-key"]
            diagnostic = String(take!(terminal.diagnostics))
            @test occursin("steer [redacted]", diagnostic) && occursin("follow [redacted]", diagnostic) && !occursin("synthetic-key", diagnostic)

            selected = resumetree()
            Agent(ResumeProvider(), []; history=selected)
            selected.store.snapshot_failure = ArgumentError("should not inspect target")
            previous, owner, status = JuliaForever.resume!(terminal, agent, source, selected)
            @test status == 1 && previous === agent && owner === source
            @test selected.store.closes == 1 && provider.calls == 0
            if source !== nothing
                previous, owner, status = JuliaForever.resume!(terminal, agent, source, source)
                @test status == 1 && previous === agent && owner === source
                @test isfile(ResumeCatalog.path(source))
                @test ResumeHistory.snapshot(source) isa ResumeHistory.Snapshot
                close(source)
            end
        end

        provider = ResumeCountingProvider(0)
        active = Agent(provider, [])
        terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), ["synthetic-key"])
        input = ResumeQueueInput(IOBuffer("1\n"), active)
        previous, owner, status = JuliaForever.resume!(terminal, active, nothing, input, target_dir)
        @test status == 1 && previous === active && owner === nothing
        @test active.state.steering == ["late synthetic-key"] && provider.calls == 0
        @test occursin("late [redacted]", String(take!(terminal.diagnostics)))

        history = ResumeHistory.Tree(ResumeHistory.Memory())
        active = Agent(ResumeCountingProvider(0), []; history)
        steer!(active, "steer synthetic-key")
        followup!(active, "follow synthetic-key")
        owner = Ref{Union{Nothing, ResumeHistory.Store}}(history)
        extensions = JuliaForever.Extensions.snapshot(JuliaForever.Extensions.Registry())
        status = JuliaForever.interact!(terminal, active, extensions, IOBuffer("/resume\n1\n/exit\n"), IOBuffer(), owner, target_dir)
        @test status == 1 && owner[] === history && active.provider.calls == 0
        @test active.state.steering == ["steer synthetic-key"] && active.state.followups == ["follow synthetic-key"]
        @test occursin("steer [redacted]", String(take!(terminal.diagnostics)))
        close(history)

        active = Agent(ResumeCountingProvider(0), [])
        raced = ResumeRaceStore(ResumeHistory.Memory(), () -> nothing, 0)
        selected = ResumeHistory.Tree(raced)
        Agent(ResumeProvider(), []; history=selected)
        sent = Ref(false)
        raced.hook = () -> sent[] || (sent[] = true; steer!(active, "raced synthetic-key"))
        previous, owner, status = JuliaForever.resume!(terminal, active, nothing, selected)
        @test status == 1 && previous === active && owner === nothing
        @test active.state.steering == ["raced synthetic-key"] && active.provider.calls == 0
        @test raced.closes == 1 && occursin("raced [redacted]", String(take!(terminal.diagnostics)))

        faulty = Agent(ResumeCountingProvider(0), [])
        faulty.fault = ResumeHistory.Rejected(:incomplete_turn)
        input = IOBuffer("1\n")
        previous, owner, status = JuliaForever.resume!(terminal, faulty, nothing, input, target_dir)
        @test status == 1 && previous === faulty && owner === nothing && position(input) == 0
        @test occursin("incomplete turn", String(take!(terminal.diagnostics)))
    end
end

@testset "explicit history releases the store on unexpected snapshot failure" begin
    database = ResumeDatabase(0)
    store = ResumeHistory.SQLite(database, ReentrantLock(), ResumeHistory.Open())
    @test_throws ArgumentError ResumeCatalog.adapt(store)
    @test database.closes == 1
end
