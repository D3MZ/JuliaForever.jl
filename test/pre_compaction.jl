module PreCompactionTests

using Test, JuliaForever, JSON3
import JuliaForever.History as H

mutable struct Provider
    replies::Vector{Completion}
    requests::Vector{Any}
end
function JuliaForever.complete(provider::Provider, messages, tools)
    push!(provider.requests, deepcopy(messages))
    popfirst!(provider.replies)
end
reply(text, tokens) = Completion(Dict{String, Any}("role" => "assistant", "content" => text), Usage(tokens, 0, 0, 0, 0, tokens, 0.01), "stop", true, nothing)
policy() = JuliaForever.UsageCompaction(100, 20, JuliaForever.RecentTokens(0))
provider() = Provider([reply("first answer", 50), reply("second answer", 81), reply("third answer", 50)], Any[])

@testset "compact saved context before a prompt" begin
    if haskey(ENV, "PI_SOURCE")
        source = ENV["PI_SOURCE"]
        @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
        oracle = JSON3.read(read(`node $(joinpath(@__DIR__, "pre_compaction_pi.mjs")) $source`, String))
        @test length(oracle.high) == 1 && only(oracle.high).reason == "threshold" && !only(oracle.high).retry
        @test isempty(oracle.boundary) && isempty(oracle.disabled) && isempty(oracle.stale)
        @test [event.reason for event in oracle.retryAfterCancelled] == ["threshold", "threshold"]
    end
    for storage in (:memory, :sqlite)
        mktempdir() do root
            path = joinpath(root, "history.sqlite")
            history = storage == :memory ? H.Memory() : open(H.SQLite, path)
            model = provider()
            agent = Agent(model, []; history)
            @test respond!(agent, "first") == "first answer"
            @test respond!(agent, "second") == "second answer"
            if storage == :sqlite
                close(history)
                history = open(H.SQLite, path)
                agent = Agent(model, []; history)
            end
            summaries = []
            events = []
            result = respond!(agent, "third"; auto_compaction=policy(), summarize=messages -> (push!(summaries, deepcopy(messages)); "checkpoint"), on_agent_event=event -> push!(events, event))
            @test result == "third answer"
            @test length(summaries) == 1
            @test !occursin("third", JSON3.write(summaries))
            @test occursin("checkpoint", JSON3.write(last(model.requests)))
            @test last(last(model.requests))["content"] == "third"
            starts = [event.type for event in events]
            @test findfirst(==(:auto_compaction_start), starts) < findfirst(==(:agent_start), starts)
            restored = Agent(model, []; history)
            @test restored.messages == agent.messages
            storage == :sqlite && close(history)
        end
    end
    for (tokens, settings) in ((80, policy()), (81, JuliaForever.AutoCompaction(100, 20; enabled=false)), (81, JuliaForever.UsageCompaction(200, 20, JuliaForever.RecentTokens(0))))
        model = Provider([reply("first answer", 50), reply("second answer", tokens), reply("third answer", 50)], Any[])
        agent = Agent(model, []; history=H.Memory())
        respond!(agent, "first")
        respond!(agent, "second")
        summaries = Ref(0)
        @test respond!(agent, "third"; auto_compaction=settings, summarize=_ -> (summaries[] += 1; "unexpected")) == "third answer"
        @test summaries[] == 0 && occursin("first answer", JSON3.write(last(model.requests)))
    end
end

@testset "pre-prompt failure and cancellation preserve input" begin
    model = provider()
    agent = Agent(model, []; history=H.Memory())
    respond!(agent, "first")
    respond!(agent, "second")
    events = []
    result = respond!(agent, "third"; auto_compaction=policy(), summarize=_ -> H.Rejected(:summary_failed), on_agent_event=event -> push!(events, event))
    @test result == "third answer"
    @test occursin("first answer", JSON3.write(last(model.requests))) && !occursin("<summary>", JSON3.write(last(model.requests)))
    @test only(event for event in events if event.type == :auto_compaction_end).result == H.Rejected(:summary_failed)

    model = provider()
    history = H.Memory()
    agent = Agent(model, []; history)
    respond!(agent, "first")
    respond!(agent, "second")
    summaries = Ref(0)
    callback = event -> event.type == :auto_compaction_start && cancel!(agent)
    result = respond!(agent, "third"; auto_compaction=policy(), summarize=_ -> (summaries[] += 1; "ignored"), on_agent_event=callback)
    @test result == :cancelled && summaries[] == 0 && length(model.requests) == 2
    @test any(message -> get(message, "role", "") == "user" && get(message, "content", "") == "third", agent.messages)
    @test Agent(model, []; history).messages == agent.messages
end

@testset "pre-prompt checks ignore stale usage after compaction" begin
    model = provider()
    history = H.Memory()
    agent = Agent(model, []; history)
    respond!(agent, "first")
    respond!(agent, "second")
    summaries = Ref(0)
    summarize = _ -> (summaries[] += 1; "checkpoint")
    @test JuliaForever.autocompact!(agent, Usage(81, 0, 0, 0, 0, 81, nothing), policy(), summarize) == "checkpoint"
    restored = Agent(model, []; history)
    @test respond!(restored, "third"; auto_compaction=policy(), summarize) == "third answer"
    @test summaries[] == 1
end

@testset "pre-prompt checks typed initial history" begin
    usage = Usage(81, 0, 0, 0, 0, 81, 0.01)
    info = JuliaForever.Conversation.ResponseInfo(usage, nothing, nothing, nothing, 1)
    initial = JuliaForever.Conversation.Message[
        JuliaForever.Conversation.User("first"),
        JuliaForever.Conversation.Assistant("first answer", JuliaForever.Conversation.ToolCall[], "stop", true; info),
    ]
    model = Provider([reply("second answer", 50)], Any[])
    agent = Agent(model, Dict{String, JuliaForever.Tool}(), initial; history=H.Memory())
    summaries = Ref(0)
    @test respond!(agent, "second"; auto_compaction=policy(), summarize=_ -> (summaries[] += 1; "checkpoint")) == "second answer"
    @test summaries[] == 1 && occursin("checkpoint", JSON3.write(only(model.requests)))

    model = Provider([reply("second answer", 50)], Any[])
    agent = Agent(model, Dict{String, JuliaForever.Tool}(), [JuliaForever.Conversation.Summary("earlier checkpoint"); initial]; history=H.Memory())
    summaries[] = 0
    @test respond!(agent, "second"; auto_compaction=policy(), summarize=_ -> (summaries[] += 1; "unexpected")) == "second answer"
    @test summaries[] == 0 && occursin("earlier checkpoint", JSON3.write(only(model.requests)))
end

@testset "pre-prompt checks context after a system update" begin
    model = provider()
    agent = Agent(model, []; history=H.Memory())
    respond!(agent, "first")
    respond!(agent, "second")
    messages = copy(getfield(agent.state, :messages))
    pushfirst!(messages, JuliaForever.Conversation.SkillContext(repeat("s", 400)))
    result, _ = JuliaForever.transition!(revision -> JuliaForever.Conversation.History(revision, messages), agent)
    @test result isa JuliaForever.Kernel.Applied
    agent.messages = [convert(Dict{String, Any}, message) for message in messages]
    summaries = Ref(0)
    @test respond!(agent, "third"; auto_compaction=policy(), summarize=_ -> (summaries[] += 1; "checkpoint")) == "third answer"
    @test summaries[] == 1 && occursin("checkpoint", JSON3.write(last(model.requests)))
    @test any(message -> get(message, "role", "") == "system" && occursin(repeat("s", 400), get(message, "content", "")), last(model.requests))
end

@testset "pre-prompt checks estimate missing usage and protect a cancelled request" begin
    model = Provider([reply("first answer", 75), reply(repeat("z", 40), 0), reply("third answer", 50)], Any[])
    agent = Agent(model, []; history=H.Memory())
    respond!(agent, "first")
    respond!(agent, "second")
    @test JuliaForever.preestimate(agent) == 87
    if haskey(ENV, "PI_SOURCE")
        oracle = JSON3.read(read(`node $(joinpath(@__DIR__, "pre_compaction_pi.mjs")) $(ENV["PI_SOURCE"])`, String))
        @test JuliaForever.preestimate(agent) == oracle.fallback.tokens
    end
    summaries = Ref(0)
    @test respond!(agent, "third"; auto_compaction=policy(), summarize=_ -> (summaries[] += 1; "checkpoint")) == "third answer"
    @test summaries[] == 1 && occursin("checkpoint", JSON3.write(last(model.requests)))

    emptyreply(text) = Completion(Dict{String, Any}("role" => "assistant", "content" => text), nothing, "stop", true, nothing)
    model = Provider([emptyreply("first answer"), emptyreply(repeat("z", 400)), reply("third answer", 50)], Any[])
    agent = Agent(model, []; history=H.Memory())
    respond!(agent, "first")
    respond!(agent, "second")
    if haskey(ENV, "PI_SOURCE")
        oracle = JSON3.read(read(`node $(joinpath(@__DIR__, "pre_compaction_pi.mjs")) $(ENV["PI_SOURCE"])`, String))
        @test JuliaForever.preestimate(agent) == oracle.unreported.tokens
    end
    summaries[] = 0
    @test respond!(agent, "third"; auto_compaction=policy(), summarize=_ -> (summaries[] += 1; "checkpoint")) == "third answer"
    @test summaries[] == 1 && occursin("checkpoint", JSON3.write(last(model.requests)))

    model = provider()
    history = H.Memory()
    agent = Agent(model, []; history)
    respond!(agent, "first")
    respond!(agent, "second")
    ready, release = Channel{Nothing}(1), Channel{Nothing}(1)
    task = Threads.@spawn respond!(agent, "third"; auto_compaction=policy(), summarize=_ -> (put!(ready, nothing); take!(release); "ignored"))
    @test timedwait(() -> isready(ready) || istaskdone(task), 10; pollint=0.01) == :ok
    @test isready(ready)
    if isready(ready)
        take!(ready)
        @test respond!(agent, "overlap") == :busy
        @test cancel!(agent)
        put!(release, nothing)
        @test fetch(task) == :cancelled && length(model.requests) == 2
        @test Agent(model, []; history).messages == agent.messages
        @test !occursin("<summary>", JSON3.write(agent.messages))
    else
        put!(release, nothing)
        wait(task)
    end
end

@testset "terminal compacts a reopened session before sending" begin
    mktempdir() do root
        agentdir = joinpath(root, "agent")
        mkpath(agentdir)
        model = (; id="small", name="Small", contextWindow=16514, maxTokens=64)
        config = (; providers=(; fixture=(; api="openai-completions", apiKey="fixture", baseUrl="http://localhost", models=[model])))
        write(joinpath(agentdir, "models.json"), JSON3.write(config))
        settings(enabled) = write(joinpath(agentdir, "settings.json"), JSON3.write((; compaction=(; enabled, keepRecentTokens=0))))
        history = joinpath(root, "session.sqlite")
        requests = joinpath(root, "requests.jsonl")
        project = dirname(@__DIR__)
        script = joinpath(@__DIR__, "terminal_auto_compaction_process.jl")
        function terminal(input)
            command = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project $script --history $history --provider fixture --model small`; dir=root)
            command = addenv(command, "HOME" => root, "PI_CODING_AGENT_DIR" => agentdir, "JF_AUTO_REQUESTS" => requests, "JF_AUTO_GATE" => nothing, "JF_AUTO_SUMMARY" => "", "JF_INSTRUCTIONS_DIR" => root, "JF_SESSION_DIR" => joinpath(root, "sessions"))
            output, diagnostics = IOBuffer(), IOBuffer()
            process = run(pipeline(ignorestatus(command); stdin=IOBuffer(input), stdout=output, stderr=diagnostics))
            (; status=process.exitcode, output=String(take!(output)), diagnostics=String(take!(diagnostics)))
        end
        settings(false)
        first = terminal("first\nsecond\n/exit\n")
        settings(true)
        resumed = terminal("third\n/exit\n")
        calls = JSON3.read.(readlines(requests))
        @test first.status == 0 && resumed.status == 0 && resumed.output == "reply:third\n"
        @test [call.operation for call in calls] == ["respond", "respond", "summarize", "respond"]
        @test !occursin("third", JSON3.write(calls[3].messages)) && occursin("checkpoint", JSON3.write(calls[4].messages))
        @test occursin("Auto-compaction complete.", resumed.diagnostics)
    end
end

@testset "interactive pre-prompt compaction" begin
    python, tmux = Sys.which("python3"), Sys.which("tmux")
    if Sys.isunix() && !isnothing(python) && !isnothing(tmux)
        project = dirname(@__DIR__)
        julia = first(Base.julia_cmd().exec)
        command = addenv(`$python $(joinpath(@__DIR__, "pre_compaction_live.py")) $project $julia`, "JULIA_DEPOT_PATH" => join(DEPOT_PATH, ':'))
        @test success(run(ignorestatus(command)))
    else
        @test_skip false
    end
end

end
