module OverflowTests

using Test, JuliaForever, JSON3, HTTP
import JuliaForever.History as H
import JuliaForever.Conversation as C
import JuliaForever.Extensions as E

mutable struct Provider
    replies::Vector{Any}
    requests::Vector{Any}
end

function JuliaForever.complete(provider::Provider, messages, tools)
    push!(provider.requests, deepcopy(messages))
    popfirst!(provider.replies)
end

struct CountingTool <: JuliaForever.Tool
    calls::Base.RefValue{Int}
end
JuliaForever.name(::CountingTool) = "counting_tool"
JuliaForever.execute(tool::CountingTool, args) = (tool.calls[] += 1; ToolResult("tool result"))

failure(error=ProviderStatus(413)) = Completion(Dict{String, Any}("role" => "assistant", "content" => "partial"), nothing, nothing, false, error)
answer(text="done") = Dict{String, Any}("role" => "assistant", "content" => text)
policy() = JuliaForever.AutoCompaction(100, 20)
initial() = Dict{String, Any}[
    Dict("role" => "system", "content" => "instructions"),
    Dict("role" => "user", "content" => "old request"),
    Dict("role" => "assistant", "content" => "old answer"),
    Dict("role" => "system", "content" => "extra instructions"),
]

@testset "overflow: retry once with a durable compacted context" begin
    if haskey(ENV, "PI_SOURCE")
        reference = JSON3.read(read(`node $(joinpath(@__DIR__, "overflow_pi.mjs")) $(ENV["PI_SOURCE"])`, String))
        @test reference.detection == [true, true, false, false]
        @test (reference.first, reference.second, reference.attempts, reference.omissions, reference.failed, reference.noProgress) == (true, false, 1, 1, true, true)
        @test (reference.liveResult.retry, reference.liveResult.omitted, reference.liveResult.compacted, reference.liveResult.failedVisible) == (true, true, true, false)
        @test [(event.reason, event.willRetry) for event in reference.liveResult.ends] == [("overflow", true)]
    end
    for storage in (:none, :memory, :sqlite)
        mktempdir() do dir
            path = joinpath(dir, "history.sqlite")
            history = storage == :none ? nothing : storage == :memory ? H.Memory() : open(H.SQLite, path)
            provider = Provider(Any[failure(), answer()], Any[])
            agent = Agent(provider, [], initial(); history)
            seen = Ref{Any}()
            events = Any[]
            registry = E.Registry()
            E.register!(registry, :watch, E.Plugin(; hooks=(:message_end => (event -> push!(events, event)),)))
            listener = E.listen(E.snapshot(registry))
            image = Image("image/png", "aW1hZ2U=")
            prompt = C.ImagePrompt("describe", [image])
            result = respond!(agent, prompt; auto_compaction=policy(), summarize=messages -> (seen[] = [convert(Dict{String, Any}, m) for m in messages]; "checkpoint"), on_agent_event=listener)
            @test result == "done"
            @test seen[] == initial()[2:3]
            @test length(provider.requests) == 2
            request = provider.requests[2]
            @test [m["role"] for m in request] == ["system", "system", "user", "user"]
            @test [m["content"] for m in request[1:2]] == ["instructions", "extra instructions"]
            @test request[3]["content"] == JuliaForever.summaryprefix * "checkpoint" * JuliaForever.summarysuffix
            @test request[4]["content"] == "describe"
            @test request[4]["images"] == [Dict("mime" => image.mime, "data" => image.data)]
            @test count(event -> get(event.message, "content", nothing) == "partial", events) == 1
            @test count(event -> get(event.message, "content", nothing) == "done", events) == 1
            @test !any(m -> get(m, "content", nothing) == "partial", agent.messages)
            if storage != :none
                expected = deepcopy(agent.messages)
                if storage == :sqlite
                    close(history)
                    history = open(H.SQLite, path)
                end
                restored = Agent(provider, []; history)
                @test restored.messages == expected
                @test restored.state.phase == C.Complete
                storage == :sqlite && close(history)
            end
        end
    end
    mktempdir() do dir
        skill = joinpath(dir, ".pi", "skills", "context", "SKILL.md")
        mkpath(dirname(skill))
        write(skill, "---\nname: context\ndescription: preserve this skill during recovery\n---\n")
        cd(dir) do
            withenv("HOME" => dir, "PI_CODING_AGENT_DIR" => joinpath(dir, "agent"), "JF_INSTRUCTIONS_DIR" => nothing) do
                provider = Provider(Any[failure(), answer()], Any[])
                seed = Agent(provider, [Read(dir)])
                messages = JuliaForever.initial(seed, nothing)
                append!(messages, C.Message[C.RawMessage(Dict("role" => "user", "content" => "old request")), C.RawMessage(Dict("role" => "assistant", "content" => "old answer"))])
                history = H.Memory()
                agent = Agent(provider, seed.tools, messages; history)
                @test respond!(agent, "current"; auto_compaction=policy(), summarize=_ -> "checkpoint") == "done"
                @test any(message -> message["role"] == "system" && occursin("preserve this skill during recovery", message["content"]), provider.requests[2])
                @test Agent(provider, []; history).messages == agent.messages
            end
        end
    end
end

@testset "overflow: tool results and lifecycle events survive retry" begin
    calls = Ref(0)
    events = Any[]
    registry = E.Registry()
    E.register!(registry, :tools, E.Plugin(; tools=(CountingTool(calls),), hooks=(:tool_result => (_ -> ToolResult("hooked result")),)))
    snapshot = E.snapshot(registry)
    call = Dict("id" => "call", "type" => "function", "function" => Dict("name" => "counting_tool", "arguments" => "{}"))
    provider = Provider(Any[Dict("role" => "assistant", "content" => nothing, "tool_calls" => [call]), failure(), answer()], Any[])
    history = H.Memory()
    agent = Agent(provider, snapshot, initial(); history)
    listener = E.listen(snapshot; on_event=event -> push!(events, event))
    @test respond!(agent, "current"; auto_compaction=policy(), summarize=_ -> "checkpoint", on_agent_event=listener) == "done"
    @test calls[] == 1
    @test length(provider.requests) == 3
    @test provider.requests[3][end-1]["tool_calls"] == [call]
    @test provider.requests[3][end]["content"] == "hooked result"
    @test count(event -> event.type == :agent_start, events) == 1
    @test count(event -> event.type == :agent_end, events) == 1
    @test count(event -> event.type == :turn_end, events) == 3
    @test Agent(provider, snapshot; history).messages == agent.messages
end

@testset "overflow: callback transcript edits survive compaction" begin
    for history in (nothing, H.Memory())
        provider = Provider(Any[failure(), answer()], Any[])
        agent = Agent(provider, Dict{String, JuliaForever.Tool}(), initial(); history)
        callback = event -> begin
            if event.type == :message_end && get(event.message, "content", nothing) == "partial"
                push!(agent.messages, Dict("role" => "system", "content" => "callback instructions"))
            end
        end
        @test respond!(agent, "current"; auto_compaction=policy(), summarize=_ -> "checkpoint", on_agent_event=callback) == "done"
        @test any(m -> get(m, "content", nothing) == "callback instructions", provider.requests[2])
        @test any(m -> get(m, "content", nothing) == "callback instructions", agent.messages)
        history === nothing || @test Agent(provider, []; history).messages == agent.messages
    end
end

@testset "overflow: a later user turn gets its own attempt" begin
    provider = Provider(Any[failure(), answer("first"), failure(), answer("second")], Any[])
    history = H.Memory()
    agent = Agent(provider, Dict{String, JuliaForever.Tool}(), initial(); history)
    followup!(agent, "follow up")
    calls = Ref(0)
    @test respond!(agent, "current"; auto_compaction=policy(), summarize=_ -> (calls[] += 1; "checkpoint $(calls[])")) == "second"
    @test calls[] == 2
    @test length(provider.requests) == 4
    @test provider.requests[4][end]["content"] == "follow up"
    @test Agent(provider, []; history).messages == agent.messages
end

@testset "overflow: steering starts a new recovery allowance" begin
    provider = Provider(Any[failure(), failure(), answer()], Any[])
    history = H.Memory()
    agent = Agent(provider, Dict{String, JuliaForever.Tool}(), initial(); history)
    calls = Ref(0)
    steered = Ref(false)
    callback = event -> begin
        if event.type == :auto_compaction_end && !steered[]
            steered[] = true
            steer!(agent, "steered")
        end
    end
    @test respond!(agent, "current"; auto_compaction=policy(), summarize=_ -> (calls[] += 1; "checkpoint $(calls[])"), on_agent_event=callback) == "done"
    @test calls[] == 2
    @test length(provider.requests) == 3
    @test provider.requests[2][end]["content"] == "steered"
    @test Agent(provider, []; history).messages == agent.messages
end

@testset "overflow: nested continuations do not inherit recovery" begin
    provider = Provider(Any[failure(), failure(), answer()], Any[])
    outer = Agent(provider, Dict{String, JuliaForever.Tool}(), initial(); history=H.Memory())
    inner_messages = vcat(initial(), [Dict{String, Any}("role" => "user", "content" => "inner")])
    inner = Agent(provider, Dict{String, JuliaForever.Tool}(), inner_messages; history=H.Memory())
    inner_result = Ref{Any}()
    started = Ref(false)
    summaries = Ref(0)
    callback = event -> begin
        if event.type == :message_end && get(event.message, "content", nothing) == "partial" && !started[]
            started[] = true
            inner_result[] = continue!(inner)
        end
    end
    result = respond!(outer, "outer"; auto_compaction=policy(), summarize=_ -> (summaries[] += 1; "checkpoint"), on_agent_event=callback)
    @test inner_result[] isa Completion && inner_result[].error == ProviderStatus(413)
    @test result == "done"
    @test summaries[] == 1
    @test length(provider.requests) == 3
    @test !any(m -> occursin("<summary>", string(get(m, "content", ""))), inner.messages)
end

@testset "overflow: stop on no progress, disabled policy, or non-overflow" begin
    for (error, settings, messages) in (
        (ProviderStatus(413), JuliaForever.AutoCompaction(100, 20; enabled=false), initial()),
        (ProviderStatus(429), policy(), initial()),
        (ProviderError(:anthropic, :rate_limit, 413), policy(), initial()),
        (ProviderError(:anthropic, :request_too_large, 429), policy(), initial()),
        (ProviderStatus(413), policy(), Dict{String, Any}[]),
    )
        provider = Provider(Any[failure(error), answer("unexpected")], Any[])
        agent = Agent(provider, [], messages; history=H.Memory())
        summaries = Ref(0)
        result = respond!(agent, "current"; auto_compaction=settings, summarize=_ -> (summaries[] += 1; "checkpoint"))
        @test result isa Completion && result.error == error
        @test length(provider.requests) == 1
        @test summaries[] == 0
        @test !any(m -> occursin("<summary>", string(get(m, "content", ""))), agent.messages)
        @test Agent(provider, []; history=agent.history).messages == agent.messages
    end
    provider = Provider(Any[failure(ProviderError(:anthropic, :request_too_large, nothing)), failure(), answer("unexpected")], Any[])
    agent = Agent(provider, [], initial(); history=H.Memory())
    calls = Ref(0)
    events = Any[]
    result = respond!(agent, "current"; auto_compaction=policy(), summarize=_ -> (calls[] += 1; "checkpoint"), on_agent_event=event -> push!(events, event))
    @test result isa Completion && result.error == ProviderStatus(413)
    @test length(provider.requests) == 2
    @test calls[] == 1
    @test [event.result for event in events if event.type == :auto_compaction_end] == ["checkpoint", H.Rejected(:overflow_retry_exhausted)]
    @test Agent(provider, []; history=agent.history).messages == agent.messages
end

@testset "overflow: compaction failure and cancellation stop retry" begin
    for outcome in (:rejected, :exception, :cancelled, :cancel_failed, :revision, :storage)
        history = H.Memory()
        provider = Provider(Any[failure(), answer("unexpected")], Any[])
        agent = Agent(provider, [], initial(); history)
        original = Ref{Any}()
        events = Any[]
        function summarize(messages)
            original[] = deepcopy(agent.messages)
            outcome == :rejected && return H.Rejected(:summary_failed)
            outcome == :exception && error("summary failed")
            outcome == :cancelled && (cancel!(agent); return "ignored")
            outcome == :cancel_failed && (cancel!(agent); return H.Rejected(:summary_failed))
            outcome == :storage && (steer!(Agent(provider, []; history), "other writer"); return "stale")
            steer!(agent, "queued")
            "stale"
        end
        result = respond!(agent, "current"; auto_compaction=policy(), summarize, on_agent_event=event -> push!(events, event))
        @test outcome in (:cancelled, :cancel_failed) ? result == :cancelled : outcome == :storage ? result == H.Rejected(:revision) : result isa Completion
        @test length(provider.requests) == 1
        @test agent.messages == original[]
        @test !agent.running
        @test Agent(provider, []; history).messages == agent.messages
        @test count(event -> event.type == :auto_compaction_end, events) == 1
        outcome in (:cancelled, :cancel_failed) && @test only(event for event in events if event.type == :auto_compaction_end).result == :cancelled
    end
end

@testset "overflow: cancellation at compaction event boundaries" begin
    for boundary in (:auto_compaction_start, :auto_compaction_end)
        history = H.Memory()
        provider = Provider(Any[failure(), answer("unexpected")], Any[])
        agent = Agent(provider, Dict{String, JuliaForever.Tool}(), initial(); history)
        calls = Ref(0)
        callback = event -> event.type == boundary && cancel!(agent)
        result = respond!(agent, "current"; auto_compaction=policy(), summarize=_ -> (calls[] += 1; "checkpoint"), on_agent_event=callback)
        @test result == :cancelled
        @test length(provider.requests) == 1
        @test calls[] == (boundary == :auto_compaction_start ? 0 : 1)
        @test Agent(provider, []; history).messages == agent.messages
    end
end

@testset "overflow: do not retry after the provider changes" begin
    for boundary in (:message_end, :auto_compaction_start, :summary, :auto_compaction_end)
        provider = Provider(Any[failure(), answer("unexpected")], Any[])
        replacement = Provider(Any[answer("unexpected")], Any[])
        history = H.Memory()
        agent = Agent(provider, Dict{String, JuliaForever.Tool}(), initial(); history)
        calls = Ref(0)
        callback = event -> begin
            if event.type == boundary && (boundary != :message_end || get(event.message, "content", nothing) == "partial")
                agent.provider = replacement
            end
        end
        summarize = _ -> begin
            calls[] += 1
            boundary == :summary && (agent.provider = replacement)
            "checkpoint"
        end
        result = respond!(agent, "current"; auto_compaction=policy(), summarize, on_agent_event=callback)
        @test result isa Completion && result.error == ProviderStatus(413)
        @test length(provider.requests) == 1 && isempty(replacement.requests)
        @test calls[] == (boundary in (:message_end, :auto_compaction_start) ? 0 : 1)
        @test Agent(replacement, []; history).messages == agent.messages
        boundary == :summary && @test !any(m -> occursin("<summary>", string(get(m, "content", ""))), agent.messages)
    end
end

@testset "overflow: an interrupted durable retry is not replayed" begin
    history = H.Memory()
    provider = Provider(Any[failure(), answer("unexpected")], Any[])
    agent = Agent(provider, Dict{String, JuliaForever.Tool}(), initial(); history)
    starts = Ref(0)
    callback = event -> begin
        if event.type == :turn_start
            starts[] += 1
            starts[] == 2 && error("interrupt before retry dispatch")
        end
    end
    @test_throws ErrorException respond!(agent, "current"; auto_compaction=policy(), summarize=_ -> "checkpoint", on_agent_event=callback)
    @test length(provider.requests) == 1
    restored = Agent(provider, []; history)
    @test restored.fault == H.Rejected(:uncertain_effect)
    @test respond!(restored, "new") == H.Rejected(:uncertain_effect)
    @test length(provider.requests) == 1
end

@testset "overflow: cancellation while summary is running" begin
    history = H.Memory()
    provider = Provider(Any[failure(), answer("unexpected")], Any[])
    agent = Agent(provider, [], initial(); history)
    started = Channel{Nothing}(1)
    release = Channel{Nothing}(1)
    task = @async respond!(agent, "current"; auto_compaction=policy(), summarize=_ -> (put!(started, nothing); take!(release); "ignored"))
    take!(started)
    @test agent.running
    @test respond!(agent, "overlap") == :busy
    @test cancel!(agent)
    put!(release, nothing)
    @test fetch(task) == :cancelled
    @test length(provider.requests) == 1
    @test !any(m -> occursin("<summary>", string(get(m, "content", ""))), agent.messages)
    @test Agent(provider, []; history).messages == agent.messages
end

@testset "overflow: cancel a stalled native summary request" begin
    ready, release = Channel{Nothing}(1), Channel{Nothing}(1)
    requests = Threads.Atomic{Int}(0)
    server = HTTP.listen!("127.0.0.1", 0; listenany=true) do io
        HTTP.startread(io)
        read(io)
        if Threads.atomic_add!(requests, 1) == 0
            HTTP.setstatus(io, 413)
            HTTP.startwrite(io)
        else
            put!(ready, nothing)
            take!(release)
            HTTP.setheader(io, "Content-Type" => "application/json")
            HTTP.startwrite(io)
            write(io, "{}")
        end
    end
    task = nothing
    try
        model = OpenAI("http://$(HTTP.server_addr(server))/v1", "fixture", "synthetic")
        history = H.Memory()
        agent = Agent(model, Dict{String, JuliaForever.Tool}(), initial(); history)
        task = Threads.@spawn respond!(agent, "current"; auto_compaction=policy())
        @test timedwait(() -> isready(ready) || istaskdone(task), 15; pollint=0.01) == :ok
        @test isready(ready)
        if isready(ready)
            take!(ready)
            @test cancel!(agent)
            stopped = timedwait(() -> istaskdone(task), 2; pollint=0.01)
            @test stopped == :ok
            stopped == :ok || put!(release, nothing)
            @test fetch(task) == :cancelled
            @test requests[] == 2
            @test Agent(model, []; history).messages == agent.messages
        end
    finally
        isready(release) || put!(release, nothing)
        close(server)
        wait(server)
        task === nothing || wait(task)
    end
end

end
