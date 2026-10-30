using Test, JuliaForever
import JuliaForever.History as QueueHistory
import JuliaForever.Conversation as QueueConversation

struct QueueResumeProvider
    calls::Base.RefValue{Int}
end
struct QueueResumeTool <: JuliaForever.Tool
    calls::Base.RefValue{Int}
end
JuliaForever.name(::QueueResumeTool) = "queue_probe"
JuliaForever.description(::QueueResumeTool) = "Track synthetic tool dispatch."
JuliaForever.schema(::QueueResumeTool) = Dict("type" => "object", "properties" => Dict())
JuliaForever.execute(tool::QueueResumeTool, args) = (tool.calls[] += 1; ToolResult("ok"))
function JuliaForever.complete(provider::QueueResumeProvider, messages, tools; kwargs...)
    provider.calls[] += 1
    Dict{String, Any}("role" => "assistant", "content" => "ok")
end
function JuliaForever.stream(provider::QueueResumeProvider, messages, tools; kwargs...)
    provider.calls[] += 1
    Completion(Dict{String, Any}("role" => "assistant", "content" => "ok"), nothing, "stop", true, nothing)
end

function queuedagent(history, provider)
    agent = Agent(provider, []; history)
    steer!(agent, "steer synthetic-key")
    followup!(agent, "follow synthetic-key")
    JuliaForever.transition!(revision -> QueueConversation.Input(revision, "prior"), agent)
    JuliaForever.transition!(revision -> QueueConversation.Interrupt(revision, "incomplete"), agent)
    agent
end

@testset "persisted queued inputs fail closed" begin
    mktempdir() do root
        provider = QueueResumeProvider(Ref(0))
        original = JuliaForever.SessionCatalog.new(root, pwd())
        prior = queuedagent(original, provider)
        @test prior.state.phase == QueueConversation.Incomplete
        @test prior.state.steering == ["steer synthetic-key"]
        @test prior.state.followups == ["follow synthetic-key"]
        path = JuliaForever.SessionCatalog.path(original)
        before = QueueHistory.snapshot(original).batches
        close(original)
        selected = QueueHistory.Tree(open(QueueHistory.SQLite, path; create=false))
        terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), ["synthetic-key"])
        tool = QueueResumeTool(Ref(0))
        registry = JuliaForever.Extensions.Registry()
        JuliaForever.Extensions.register!(registry, :probe, JuliaForever.Extensions.Plugin(; tools=(tool,)))
        extensions = JuliaForever.Extensions.snapshot(registry)
        @test JuliaForever.runsession!(selected, terminal, provider, extensions, ["do not send"], root) == 1
        @test provider.calls[] == 0 && tool.calls[] == 0
        output = String(take!(terminal.diagnostics))
        @test occursin("steer [redacted]", output) && occursin("follow [redacted]", output)
        @test occursin("remain saved", output) && !occursin("synthetic-key", output)
        reopened = QueueHistory.Tree(open(QueueHistory.SQLite, path; create=false))
        @test QueueHistory.snapshot(reopened).batches == before
        active_history = QueueHistory.Tree(QueueHistory.Memory())
        active = Agent(provider, [tool]; history=active_history)
        unchanged, history, status = JuliaForever.resume!(terminal, active, active_history, reopened)
        @test status == 1 && unchanged === active && history === active_history
        @test provider.calls[] == 0 && tool.calls[] == 0
        @test QueueHistory.snapshot(reopened) == QueueHistory.Rejected(:closed)
        output = String(take!(terminal.diagnostics))
        @test occursin("steer [redacted]", output) && occursin("follow [redacted]", output)
        @test QueueHistory.snapshot(active_history) isa QueueHistory.Snapshot
        owner = Ref{Union{Nothing, QueueHistory.Store}}(active_history)
        status = JuliaForever.interact!(terminal, active, extensions, IOBuffer("/resume\n1\n/exit\n"), IOBuffer(), owner, root)
        @test status == 1 && owner[] === active_history
        @test provider.calls[] == 0 && tool.calls[] == 0
        @test occursin("follow [redacted]", String(take!(terminal.diagnostics)))
        preserved = QueueHistory.Tree(open(QueueHistory.SQLite, path; create=false))
        @test QueueHistory.snapshot(preserved).batches == before
        close(preserved)
        close(active_history)
    end
end

@testset "ephemeral queues block resume and branch edits" begin
    provider = QueueResumeProvider(Ref(0))
    current = QueueHistory.Tree(QueueHistory.Memory())
    active = Agent(provider, []; history=current)
    selected = QueueHistory.Tree(QueueHistory.Memory())
    queuedagent(selected, provider)
    terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), ["synthetic-key"])
    unchanged, history, status = JuliaForever.resume!(terminal, active, current, selected)
    @test status == 1 && unchanged === active && history === current
    @test provider.calls[] == 0
    output = String(take!(terminal.diagnostics))
    @test occursin("only in memory", output) && !occursin("remain saved", output)
    close(current)

    tree = QueueHistory.Tree(QueueHistory.Memory())
    agent = queuedagent(tree, provider)
    target = tree.leaf
    @test respond!(agent, "clear") == "ok"
    @test isempty(agent.state.steering) && isempty(agent.state.followups)
    previous_leaf = tree.leaf
    calls = provider.calls[]
    for choice in (JuliaForever.TreeTerminal.Edit(target, "do not send"), JuliaForever.TreeTerminal.Move(target))
        unchanged, selected_tree, status = JuliaForever.tree!(terminal, agent, tree, choice, nothing)
        @test status == 1 && unchanged === agent && selected_tree === tree
        @test tree.leaf == previous_leaf && provider.calls[] == calls
        output = String(take!(terminal.diagnostics))
        @test occursin("steer [redacted]", output) && occursin("follow [redacted]", output)
        @test occursin("only in memory", output)
    end
    close(tree)
end

@testset "tree moves preserve active queues and faults" begin
    mktempdir() do root
        for history in (QueueHistory.Tree(QueueHistory.Memory()), JuliaForever.SessionCatalog.new(root, pwd()))
            provider = QueueResumeProvider(Ref(0))
            agent = Agent(provider, []; history)
            target = history.leaf
            steer!(agent, "steer synthetic-key")
            followup!(agent, "follow synthetic-key")
            leaf = history.leaf
            terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), ["synthetic-key"])
            for choice in (JuliaForever.TreeTerminal.Move(target), JuliaForever.TreeTerminal.Edit(target, "do not send"))
                previous, owner, status = JuliaForever.tree!(terminal, agent, history, choice, nothing)
                @test status == 1 && previous === agent && owner === history
                @test history.leaf == leaf && provider.calls[] == 0
                diagnostic = String(take!(terminal.diagnostics))
                @test occursin("steer [redacted]", diagnostic) && occursin("follow [redacted]", diagnostic)
            end
            close(history)
        end
        history = QueueHistory.Tree(QueueHistory.Memory())
        provider = QueueResumeProvider(Ref(0))
        agent = Agent(provider, []; history)
        agent.fault = QueueHistory.Rejected(:incomplete_turn)
        terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), String[])
        for choice in (JuliaForever.TreeTerminal.Move(history.leaf), JuliaForever.TreeTerminal.Edit(history.leaf, "do not send"))
            previous, owner, status = JuliaForever.tree!(terminal, agent, history, choice, nothing)
            @test status == 1 && previous === agent && owner === history && provider.calls[] == 0
            @test occursin("incomplete turn", String(take!(terminal.diagnostics)))
        end
        close(history)
    end
end
