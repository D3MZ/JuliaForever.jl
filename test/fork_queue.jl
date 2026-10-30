using Test, JSON3, JuliaForever
import JuliaForever.History as QueueForkHistory

mutable struct QueueForkProvider
    requests::Vector{Any}
end

struct ForkQueueTool <: JuliaForever.Tool
    calls::Base.RefValue{Int}
end
JuliaForever.name(::ForkQueueTool) = "fork_queue_tool"
JuliaForever.execute(tool::ForkQueueTool, args) = (tool.calls[] += 1; ToolResult("tool result", false))

mutable struct ForkToolProvider
    requests::Vector{Any}
end
function JuliaForever.stream(provider::ForkToolProvider, messages, tools; parameters=Dict(), on_event=identity)
    push!(provider.requests, deepcopy(messages))
    if length(provider.requests) == 1
        call = Dict("id" => "call-1", "type" => "function", "function" => Dict("name" => "fork_queue_tool", "arguments" => "{}"))
        result = Completion(Dict{String, Any}("role" => "assistant", "content" => nothing, "tool_calls" => [call]), nothing, "tool_calls", true, nothing)
    else
        text = "reply:" * messages[end]["content"]
        on_event((; type=:text, text))
        result = Completion(Dict{String, Any}("role" => "assistant", "content" => text), nothing, "stop", true, nothing)
    end
    on_event((; type=:done, result))
    result
end
function JuliaForever.stream(provider::QueueForkProvider, messages, tools; parameters=Dict(), on_event=identity)
    push!(provider.requests, deepcopy(messages))
    text = "reply:" * messages[end]["content"]
    on_event((; type=:text, text))
    Completion(Dict{String, Any}("role" => "assistant", "content" => text), nothing, "stop", true, nothing)
end

@testset "fork steering after a completed tool" begin
    store = QueueForkHistory.Memory()
    source = QueueForkHistory.Tree(store)
    provider = ForkToolProvider([])
    calls = Ref(0)
    agent = Agent(provider, [ForkQueueTool(calls)]; history=source)
    queued = Ref(false)
    callback = event -> begin
        if event.type == :tool_execution_end && !queued[]
            queued[] = true
            steer!(agent, "after tool")
        end
    end
    @test respond!(agent, "first"; on_event=identity, on_agent_event=callback) == "reply:after tool"
    @test calls[] == 1
    before = QueueForkHistory.snapshot(store).batches
    output = IOBuffer()
    terminal = JuliaForever.Terminal(output, IOBuffer(), String[])
    forked, history, status = JuliaForever.command!(JuliaForever.ForkCommand(), terminal, agent, source, IOBuffer("2\nreplacement\n"), "", nothing)
    @test status == 0
    @test String(take!(output)) == "reply:replacement\n"
    @test [message["role"] for message in last(provider.requests)] == ["user", "assistant", "tool", "user"]
    @test last(last(provider.requests))["content"] == "replacement"
    @test calls[] == 1
    @test QueueForkHistory.snapshot(store).batches == before
    close(history)
end

@testset "fork queued user messages" begin
    store = QueueForkHistory.Memory()
    source = QueueForkHistory.Tree(store)
    provider = QueueForkProvider([])
    agent = Agent(provider, []; history=source)
    queued = Ref(false)
    callback = event -> begin
        if event.type == :message_start && event.message["role"] == "assistant" && !queued[]
            queued[] = true
            steer!(agent, "steer")
            followup!(agent, "follow")
        end
    end
    @test respond!(agent, "first"; on_event=identity, on_agent_event=callback) == "reply:follow"
    @test [message["content"] for message in agent.messages] == ["first", "reply:first", "steer", "reply:steer", "follow", "reply:follow"]
    before = QueueForkHistory.snapshot(store).batches

    output = IOBuffer()
    diagnostics = IOBuffer()
    terminal = JuliaForever.Terminal(output, diagnostics, String[])
    forked, history, status = JuliaForever.command!(JuliaForever.ForkCommand(), terminal, agent, source, IOBuffer("2\nreplacement\n"), "", nothing)
    @test status == 0
    @test String(take!(output)) == "reply:replacement\n"
    @test [message["content"] for message in last(provider.requests)] == ["first", "reply:first", "replacement"]
    steercontext = [message["content"] for message in last(provider.requests)][1:end-1]
    @test QueueForkHistory.snapshot(store).batches == before
    close(history)

    source = QueueForkHistory.Tree(store)
    agent = Agent(provider, []; history=source)
    output = IOBuffer()
    terminal = JuliaForever.Terminal(output, IOBuffer(), String[])
    forked, history, status = JuliaForever.command!(JuliaForever.ForkCommand(), terminal, agent, source, IOBuffer("3\nreplacement follow\n"), "", nothing)
    @test status == 0
    @test String(take!(output)) == "reply:replacement follow\n"
    @test [message["content"] for message in last(provider.requests)] == ["first", "reply:first", "steer", "reply:steer", "replacement follow"]
    followcontext = [message["content"] for message in last(provider.requests)][1:end-1]
    @test QueueForkHistory.snapshot(store).batches == before
    if haskey(ENV, "PI_SOURCE")
        source = ENV["PI_SOURCE"]
        @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
        reference = JSON3.read(read(`node $(joinpath(@__DIR__, "fork_pi.mjs")) $source`, String))
        @test steercontext == reference.beforeSteer
        @test followcontext == reference.beforeFollow
    end
    close(history)
end

@testset "persist and reopen a queued-message fork" begin
    mktempdir() do directory
        sourcepath = joinpath(directory, "source.sqlite")
        store = open(QueueForkHistory.SQLite, sourcepath)
        source = QueueForkHistory.Tree(store)
        provider = QueueForkProvider([])
        agent = Agent(provider, []; history=source)
        queued = Ref(false)
        callback = event -> begin
            if event.type == :message_start && event.message["role"] == "assistant" && !queued[]
                queued[] = true
                steer!(agent, "steer")
                followup!(agent, "follow")
            end
        end
        @test respond!(agent, "first"; on_event=identity, on_agent_event=callback) == "reply:follow"
        before = QueueForkHistory.snapshot(store).batches
        terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), String[])
        forked, history, status = JuliaForever.command!(JuliaForever.ForkCommand(), terminal, agent, source, IOBuffer("2\nreplacement\n"), directory, nothing)
        @test status == 0
        path = JuliaForever.SessionCatalog.path(history)
        @test path != sourcepath && isfile(path)
        close(history)

        original = open(QueueForkHistory.SQLite, sourcepath; create=false)
        @test QueueForkHistory.snapshot(original).batches == before
        close(original)
        copied = QueueForkHistory.Tree(open(QueueForkHistory.SQLite, path; create=false))
        restored = Agent(provider, []; history=copied)
        @test restored.fault === nothing
        @test [message["content"] for message in restored.messages] == ["first", "reply:first", "replacement", "reply:replacement"]
        close(copied)
    end
end

@testset "fork and clone preserve queued input and faults" begin
    for command in (JuliaForever.CloneCommand(), JuliaForever.ForkCommand())
        history = QueueForkHistory.Tree(QueueForkHistory.Memory())
        provider = QueueForkProvider([])
        agent = Agent(provider, []; history)
        @test respond!(agent, "first"; on_event=identity) == "reply:first"
        steer!(agent, "keep synthetic-key")
        followup!(agent, "later synthetic-key")
        before = QueueForkHistory.snapshot(history).batches
        calls = length(provider.requests)
        diagnostics = IOBuffer()
        terminal = JuliaForever.Terminal(IOBuffer(), diagnostics, ["synthetic-key"])
        original, owner, status = JuliaForever.command!(command, terminal, agent, history, IOBuffer("1\n"), "", nothing)
        @test status == 1 && original === agent && owner === history
        @test length(provider.requests) == calls && QueueForkHistory.snapshot(history).batches == before
        @test agent.state.steering == ["keep synthetic-key"] && agent.state.followups == ["later synthetic-key"]
        output = String(take!(diagnostics))
        @test occursin("keep [redacted]", output) && occursin("later [redacted]", output) && !occursin("synthetic-key", output)
        close(history)
    end
end

@testset "fork and clone reject active faults" begin
    for command in (JuliaForever.CloneCommand(), JuliaForever.ForkCommand())
        history = QueueForkHistory.Tree(QueueForkHistory.Memory())
        provider = QueueForkProvider([])
        agent = Agent(provider, []; history)
        agent.fault = QueueForkHistory.Rejected(:incomplete_turn)
        terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), String[])
        original, owner, status = JuliaForever.command!(command, terminal, agent, history, IOBuffer("1\n"), "", nothing)
        @test status == 1 && original === agent && owner === history
        @test isempty(provider.requests) && QueueForkHistory.snapshot(history) isa QueueForkHistory.Snapshot
        close(history)
    end
end

@testset "fork diagnostics redact while preserving the draft and plugin hooks" begin
    history = QueueForkHistory.Tree(QueueForkHistory.Memory())
    provider = QueueForkProvider([])
    agent = Agent(provider, []; history)
    @test respond!(agent, "original synthetic-key"; on_event=identity) == "reply:original synthetic-key"
    events = Symbol[]
    registry = JuliaForever.Extensions.Registry()
    plugin = JuliaForever.Extensions.Plugin(; hooks=(:agent_start => (event -> push!(events, :start)),))
    @test JuliaForever.Extensions.register!(registry, :fork_test, plugin)
    snapshot = JuliaForever.Extensions.snapshot(registry)
    diagnostics = IOBuffer()
    terminal = JuliaForever.Terminal(IOBuffer(), diagnostics, ["synthetic-key"])
    selected, forked, status = JuliaForever.readcommand!(terminal, agent, snapshot, history, "/fork", IOBuffer("1\n\n"), "", Dict{String, String}(), JuliaForever.ForkCommand())
    @test status == 0 && events == [:start]
    @test last(provider.requests)[end]["content"] == "original synthetic-key"
    output = String(take!(diagnostics))
    @test occursin("original [redacted]", output) && !occursin("synthetic-key", output)
    close(forked)

    history = QueueForkHistory.Tree(QueueForkHistory.Memory())
    agent = Agent(provider, []; history)
    @test respond!(agent, "first"; on_event=identity) == "reply:first"
    selected, forked, status = JuliaForever.readcommand!(terminal, agent, snapshot, history, "/fork", IOBuffer("1\n/example hello\n"), "", Dict("example" => "expanded \$1"), JuliaForever.ForkCommand())
    @test status == 0 && last(provider.requests)[end]["content"] == "expanded hello"
    @test events == [:start, :start]
    close(forked)
end

@testset "fork copy failure preserves the source" begin
    mktempdir() do root
        source = JuliaForever.SessionCatalog.new(root, pwd())
        provider = QueueForkProvider([])
        agent = Agent(provider, []; history=source)
        @test respond!(agent, "first"; on_event=identity) == "reply:first"
        before = QueueForkHistory.snapshot(source).batches
        path = joinpath(root, "synthetic-key")
        write(path, "not a directory")
        diagnostics = IOBuffer()
        terminal = JuliaForever.Terminal(IOBuffer(), diagnostics, ["synthetic-key"])
        original, owner, status = JuliaForever.command!(JuliaForever.CloneCommand(), terminal, agent, source, IOBuffer(), path, nothing)
        @test status == 1 && original === agent && owner === source
        @test QueueForkHistory.snapshot(source).batches == before
        @test !occursin("synthetic-key", String(take!(diagnostics)))
        @test respond!(agent, "next"; on_event=identity) == "reply:next"
        close(source)
    end
end

@testset "command-line fork refuses saved queued input without a copy" begin
    mktempdir() do root
        history = JuliaForever.SessionCatalog.new(root, pwd())
        provider = QueueForkProvider([])
        agent = Agent(provider, []; history)
        @test respond!(agent, "first"; on_event=identity) == "reply:first"
        steer!(agent, "saved steering")
        source = JuliaForever.SessionCatalog.path(history)
        before = QueueForkHistory.snapshot(history).batches
        close(history)
        files = Set(readdir(root))
        selected = JuliaForever.SessionCatalog.choose(JuliaForever.SessionCatalog.Fork(source), root, pwd(), IOBuffer(), IOBuffer())
        @test selected == QueueForkHistory.Rejected(:pending_inputs)
        @test Set(readdir(root)) == files
        reopened = QueueForkHistory.Tree(open(QueueForkHistory.SQLite, source; create=false))
        @test QueueForkHistory.snapshot(reopened).batches == before
        close(reopened)
    end
end

@testset "fork switch refuses an active request" begin
    mktempdir() do root
        source = QueueForkHistory.Tree(QueueForkHistory.Memory())
        provider = QueueForkProvider([])
        agent = Agent(provider, []; history=source)
        target = QueueForkHistory.Tree(open(QueueForkHistory.SQLite, joinpath(root, "target.sqlite")))
        Agent(provider, []; history=target)
        JuliaForever.transition!(revision -> JuliaForever.Conversation.Input(revision, "in flight"), agent)
        terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), String[])
        original, owner, status = JuliaForever.switch!(terminal, agent, source, target, "switched", () -> nothing)
        @test status == 1 && original === agent && owner === source
        @test QueueForkHistory.snapshot(source) isa QueueForkHistory.Snapshot
        @test QueueForkHistory.snapshot(target) == QueueForkHistory.Rejected(:closed)
        close(source)
    end
end
