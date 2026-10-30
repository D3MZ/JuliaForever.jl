module CompactionUsageTests

using Test, JuliaForever, JSON3

const project = dirname(@__DIR__)
const process = joinpath(@__DIR__, "compaction_cli_process.jl")

function terminal(root, history, mode, args, input)
    path = joinpath(root, "agent", "settings.json")
    mkpath(dirname(path))
    isfile(path) || write(path, JSON3.write((; compaction=(; keepRecentTokens=5))))
    command = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project $process --history $history $args`; dir=root)
    command = addenv(command, "HOME" => root, "JF_COMPACTION_USAGE" => mode, "JF_COMPACTION_REQUESTS" => joinpath(root, "requests"), "JF_SESSION_DIR" => joinpath(root, "sessions"), "PI_CODING_AGENT_DIR" => joinpath(root, "agent"), "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "synthetic", "OPENAI_BASE_URL" => nothing, "JF_INSTRUCTIONS_DIR" => root)
    output, diagnostics = IOBuffer(), IOBuffer()
    result = run(pipeline(ignorestatus(command); stdin=IOBuffer(input), stdout=output, stderr=diagnostics))
    (; status=result.exitcode, output=String(take!(output)), diagnostics=String(take!(diagnostics)))
end

@testset "compaction usage survives reopening" begin
    mktempdir() do root
        history = joinpath(root, "session.sqlite")
        initial = terminal(root, history, "success", String[], "first\nsecond\n/compact\n/session\n/exit\n")
        @test initial.status == 0 && occursin("Context compacted.", initial.diagnostics)
        @test occursin("User: 2", initial.diagnostics) && occursin("Assistant: 2", initial.diagnostics)
        @test occursin("Input: 285", initial.diagnostics) && occursin("Output: 28", initial.diagnostics) && occursin("Total: 313", initial.diagnostics)
        @test occursin("Total: \$0.022", initial.diagnostics)
        reopened = terminal(root, history, "success", String[], "/session\n/exit\n")
        @test reopened.status == 0 && occursin("Total: 313", reopened.diagnostics) && occursin("Total: \$0.022", reopened.diagnostics)
        rpc = terminal(root, history, "success", ["--mode", "rpc"], JSON3.write((; id="stats", type="get_session_stats")) * "\n")
        records = JSON3.read.(split(chomp(rpc.output), '\n'))
        stats = only(filter(row -> get(row, :id, "") == "stats", records))
        @test stats.success && stats.data.tokens.total == 313 && stats.data.cost ≈ 0.022
        if haskey(ENV, "PI_SOURCE")
            source = ENV["PI_SOURCE"]
            @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
            oracle = JSON3.read(read(`node $(joinpath(@__DIR__, "compaction_usage_pi.mjs")) $source`, String))
            @test stats.data.tokens.total == oracle.tokens.total && stats.data.cost ≈ oracle.cost
            @test stats.data.userMessages == oracle.userMessages && stats.data.assistantMessages == oracle.assistantMessages && stats.data.totalMessages == oracle.totalMessages
        end
    end
    mktempdir() do root
        history = joinpath(root, "session.sqlite")
        failed = terminal(root, history, "failure", String[], "first\nsecond\n/compact\n/session\n/exit\n")
        @test failed.status == 1 && !occursin("Context compacted.", failed.diagnostics)
        @test occursin("Total: 313", failed.diagnostics) && occursin("Total: \$0.022", failed.diagnostics)
        resumed = terminal(root, history, "success", ["third"], "")
        @test resumed.status == 0 && resumed.output == "reply:third\n"
        requests = JSON3.read.(readlines(joinpath(root, "requests")))
        @test [request.operation for request in requests] == ["respond", "respond", "summarize", "respond"]
        @test occursin("reply:first", JSON3.write(requests[end].messages))
        rpc = terminal(root, history, "success", ["--mode", "rpc"], JSON3.write((; id="stats", type="get_session_stats")) * "\n")
        records = JSON3.read.(split(chomp(rpc.output), '\n'))
        stats = only(filter(row -> get(row, :id, "") == "stats", records))
        @test stats.success && stats.data.tokens.total == 443 && stats.data.cost ≈ 0.032
    end
    mktempdir() do root
        history = joinpath(root, "session.sqlite")
        missing = terminal(root, history, "missing", String[], "first\nsecond\n/compact\n/session\n/exit\n")
        @test missing.status == 0 && occursin("Tokens\nInput: Unavailable", missing.diagnostics)
        reopened = terminal(root, history, "missing", String[], "/session\n/exit\n")
        @test occursin("Tokens\nInput: Unavailable", reopened.diagnostics)
    end
end

mutable struct UsageProvider
    replies::Vector{Completion}
    action::Function
end
function JuliaForever.complete(provider::UsageProvider, messages, tools)
    result = popfirst!(provider.replies)
    provider.action()
    result
end
reply(text, usage) = Completion(Dict{String, Any}("role" => "assistant", "content" => text), usage, "stop", true, nothing)

@testset "compaction accounting preserves branches and concurrent input" begin
    normal = Usage(100, 10, 20, 0, 0, 130, 0.01)
    summary = Usage(40, 8, 5, 0, 0, 53, 0.002)
    provider = UsageProvider([reply("first answer", normal), reply("second answer", normal), reply("checkpoint", summary), reply("other checkpoint", summary)], () -> nothing)
    history = JuliaForever.History.Tree(JuliaForever.History.Memory())
    agent = Agent(provider, []; history)
    @test respond!(agent, "first") == "first answer"
    @test respond!(agent, "second") == "second answer"
    before = agent.history_revision
    @test compact!(agent) == "checkpoint"
    events = JSON3.read(JuliaForever.Logs.json(agent.events))
    @test any(event -> get(event, :type, "") == "history" && haskey(event, :compaction) && event.compaction.usage.total == 53, events)
    @test JuliaForever.History.branch!(history, before) == before
    branched = Agent(provider, []; history)
    @test compact!(branched) == "other checkpoint"
    counts = JuliaForever.SessionInfo.counts(branched, history)
    @test (counts.user, counts.assistant, counts.total) == (2, 2, 4)
    @test counts.usage.input + counts.usage.output + counts.usage.cache_read == 366 && counts.usage.cost ≈ 0.024

    provider = UsageProvider([reply("first answer", normal), reply("second answer", normal), reply("memory checkpoint", summary)], () -> nothing)
    agent = Agent(provider, [])
    respond!(agent, "first")
    respond!(agent, "second")
    @test compact!(agent) == "memory checkpoint"
    counts = JuliaForever.SessionInfo.counts(agent, nothing)
    @test counts.usage.input + counts.usage.output + counts.usage.cache_read == 313 && counts.usage.cost ≈ 0.022

    provider = UsageProvider([reply("first answer", normal), reply("second answer", normal), reply("stale checkpoint", summary)], () -> nothing)
    history = JuliaForever.History.Tree(JuliaForever.History.Memory())
    agent = Agent(provider, []; history)
    respond!(agent, "first")
    respond!(agent, "second")
    before = deepcopy(agent.messages)
    provider.action = () -> steer!(agent, "queued")
    @test compact!(agent) == JuliaForever.History.Rejected(:revision)
    @test agent.messages == before && agent.state.steering == ["queued"]
    counts = JuliaForever.SessionInfo.counts(agent, history)
    @test counts.usage.input + counts.usage.output + counts.usage.cache_read == 313 && counts.usage.cost ≈ 0.022

    provider = UsageProvider([reply("first answer", normal), reply("second answer", normal), reply("cancelled checkpoint", summary)], () -> nothing)
    history = JuliaForever.History.Tree(JuliaForever.History.Memory())
    agent = Agent(provider, []; history)
    respond!(agent, "first")
    respond!(agent, "second")
    before = deepcopy(agent.messages)
    provider.action = () -> cancel!(agent)
    @test compact!(agent) == :cancelled && agent.messages == before
    counts = JuliaForever.SessionInfo.counts(agent, history)
    @test counts.usage.input + counts.usage.output + counts.usage.cache_read == 313 && counts.usage.cost ≈ 0.022

    provider = UsageProvider([reply("first answer", normal), reply("second answer", normal), reply("automatic checkpoint", summary)], () -> nothing)
    history = JuliaForever.History.Tree(JuliaForever.History.Memory())
    agent = Agent(provider, []; history)
    @test respond!(agent, "first") == "first answer"
    @test respond!(agent, "second"; auto_compaction=JuliaForever.AutoCompaction(100, 20)) == "second answer"
    @test any(message -> occursin("automatic checkpoint", string(get(message, "content", ""))), agent.messages)
    counts = JuliaForever.SessionInfo.counts(agent, history)
    @test counts.usage.input + counts.usage.output + counts.usage.cache_read == 313 && counts.usage.cost ≈ 0.022

    failed = Usage(5, 1, 0, 0, 0, 6, 0.001)
    overflow = Completion(Dict{String, Any}("role" => "assistant", "content" => "partial"), failed, nothing, false, ProviderStatus(413))
    provider = UsageProvider([reply("first answer", normal), overflow, reply("recovery checkpoint", summary), reply("recovered", normal)], () -> nothing)
    history = JuliaForever.History.Tree(JuliaForever.History.Memory())
    agent = Agent(provider, []; history)
    @test respond!(agent, "first") == "first answer"
    @test respond!(agent, "second"; auto_compaction=JuliaForever.AutoCompaction(1000, 100)) == "recovered"
    @test any(message -> occursin("recovery checkpoint", string(get(message, "content", ""))), agent.messages)
    counts = JuliaForever.SessionInfo.counts(agent, history)
    @test counts.usage.input + counts.usage.output + counts.usage.cache_read == 319 && counts.usage.cost ≈ 0.023

    unpriced = Usage(40, 8, 5, 0, 0, 53, nothing)
    provider = UsageProvider([reply("first answer", normal), reply("second answer", normal), reply("unpriced checkpoint", unpriced)], () -> nothing)
    history = JuliaForever.History.Tree(JuliaForever.History.Memory())
    agent = Agent(provider, []; history)
    respond!(agent, "first")
    respond!(agent, "second")
    @test compact!(agent) == "unpriced checkpoint"
    counts = JuliaForever.SessionInfo.counts(agent, history)
    @test counts.usage.input + counts.usage.output + counts.usage.cache_read == 313 && isnothing(counts.usage.cost)

    failed = Completion(Dict{String, Any}("role" => "assistant", "content" => "partial"), nothing, "length", true, nothing)
    provider = UsageProvider([reply("first answer", normal), reply("second answer", normal), failed], () -> nothing)
    history = JuliaForever.History.Tree(JuliaForever.History.Memory())
    agent = Agent(provider, []; history)
    respond!(agent, "first")
    respond!(agent, "second")
    before = deepcopy(agent.messages)
    @test compact!(agent) == JuliaForever.History.Rejected(:summary_failed) && agent.messages == before
    @test JuliaForever.SessionInfo.counts(agent, history).usage isa JuliaForever.SessionInfo.UnknownUsage
end

@testset "terminal compaction preserves history on interruption" begin
    normal = Usage(100, 10, 0, 0, 0, 110, nothing)
    summary = Usage(10, 1, 0, 0, 0, 11, nothing)
    for (action, expected) in ((agent -> steer!(agent, "queued"), 1), (agent -> cancel!(agent), 130))
        provider = UsageProvider([reply("first answer", normal), reply("second answer", normal), reply("checkpoint", summary)], () -> nothing)
        history = JuliaForever.History.Tree(JuliaForever.History.Memory())
        agent = Agent(provider, []; history)
        respond!(agent, "first")
        respond!(agent, "second")
        before = deepcopy(agent.messages)
        provider.action = () -> action(agent)
        terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), String[])
        _, _, status = JuliaForever.command!(JuliaForever.terminalcommands["/compact"], terminal, agent, history, IOBuffer(), "", nothing)
        @test status == expected && agent.messages == before && !agent.running
        @test !any(event -> event isa JuliaForever.Conversation.SessionRecord{JuliaForever.Conversation.CompactionEntry}, agent.events)
        @test Agent(provider, []; history).messages == before
    end
end

end
