using Test, JuliaForever
import JuliaForever.Conversation as CompactConversation
import JuliaForever.History as CompactHistory

mutable struct CompactProvider
    response::Any
    requests::Vector{Any}
end

function JuliaForever.complete(provider::CompactProvider, messages, tools)
    push!(provider.requests, (; messages=deepcopy(messages), tools=deepcopy(tools)))
    deepcopy(provider.response)
end

function compactmessages()
    Dict{String, Any}[
        Dict("role" => "system", "content" => "instructions"),
        Dict("role" => "user", "content" => "first"),
        Dict("role" => "assistant", "content" => "first answer"),
        Dict("role" => "user", "content" => "second"),
        Dict("role" => "assistant", "content" => nothing, "tool_calls" => [Dict("id" => "call", "type" => "function", "function" => Dict("name" => "read", "arguments" => "{}"))]),
        Dict("role" => "tool", "tool_call_id" => "call", "content" => "file contents"),
        Dict("role" => "assistant", "content" => "second answer"),
    ]
end

function compactagent(provider; history=nothing)
    Agent(provider, Dict{String, JuliaForever.Tool}(), compactmessages(); history)
end

@testset "compaction retains all system context" begin
    messages = compactmessages()
    insert!(messages, 2, Dict{String, Any}("role" => "system", "content" => "<skills>metadata</skills>"))
    push!(messages, Dict{String, Any}("role" => "system", "content" => "late system"))
    provider = CompactProvider(Dict{String, Any}("role" => "assistant", "content" => "done"), Any[])
    agent = Agent(provider, Dict{String, JuliaForever.Tool}(), messages; history=CompactHistory.Memory())
    @test compact!(agent, _ -> "checkpoint") == "checkpoint"
    @test [message["content"] for message in agent.messages if message["role"] == "system"] == ["instructions", "<skills>metadata</skills>", "late system"]
end

@testset "compaction retains the latest image turn" begin
    history = CompactHistory.Memory()
    provider = CompactProvider(Dict{String, Any}("role" => "assistant", "content" => "image answer"), Any[])
    agent = compactagent(provider; history)
    original = deepcopy(agent.messages)
    image = Image("image/png", "aW1hZ2U=")
    prompt = CompactConversation.ImagePrompt("describe", [image])
    @test respond!(agent, prompt) == "image answer"
    seen = Ref{Any}()
    @test compact!(agent, messages -> (seen[] = [convert(Dict{String, Any}, message) for message in messages]; "checkpoint")) == "checkpoint"
    @test seen[] == original[2:end]
    @test agent.messages[end-1]["images"] == [Dict("mime" => image.mime, "data" => image.data)]
    @test agent.messages[end]["content"] == "image answer"
    @test Agent(provider, []; history).messages == agent.messages
end

@testset "compaction preserves turns, branches, and previous summaries" begin
    history = CompactHistory.Tree(CompactHistory.Memory())
    provider = CompactProvider(Dict{String, Any}("role" => "assistant", "content" => "third answer"), Any[])
    agent = compactagent(provider; history)
    original = deepcopy(agent.messages)
    before = agent.history_revision
    seen = Ref{Any}()
    @test compact!(agent, messages -> (seen[] = messages; "first checkpoint")) == "first checkpoint"
    @test [convert(Dict{String, Any}, message) for message in seen[]] == original[2:3]
    @test agent.messages[3:end] == original[4:end]
    compacted = agent.history_revision
    @test CompactHistory.branch!(history, before) == before
    @test Agent(provider, []; history).messages == original
    @test CompactHistory.branch!(history, compacted) == compacted
    agent = Agent(provider, []; history)
    @test respond!(agent, "third") == "third answer"
    @test compact!(agent, messages -> (seen[] = messages; "updated checkpoint")) == "updated checkpoint"
    @test first(seen[]) isa CompactConversation.Summary
    @test first(seen[]).content == "first checkpoint"
    @test [convert(Dict{String, Any}, message) for message in seen[][2:end]] == original[4:end]
    @test [message["content"] for message in agent.messages] == ["instructions", JuliaForever.summaryprefix * "updated checkpoint" * JuliaForever.summarysuffix, "third", "third answer"]
    @test Agent(provider, []; history).messages == agent.messages
    @test compact!(agent, _ -> "must not run") == CompactHistory.Rejected(:nothing_to_compact)
end

@testset "failed and concurrent compactions preserve the transcript" begin
    failure = CompactHistory.Rejected(:summary_failed)
    for response in (
        Completion(Dict{String, Any}("role" => "assistant", "content" => "partial"), nothing, "length", true, nothing),
        Completion(Dict{String, Any}("role" => "assistant", "content" => "partial"), nothing, "stop", false, "interrupted"),
        Completion(Dict{String, Any}("role" => "assistant", "content" => "bad"), nothing, "stop", true, "failed"),
        Dict{String, Any}("role" => "assistant", "content" => "", "tool_calls" => [Dict("id" => "call")]),
        Dict{String, Any}("role" => "assistant", "content" => "   "),
    )
        provider = CompactProvider(response, Any[])
        history = CompactHistory.Memory()
        agent = compactagent(provider; history)
        original, revision = deepcopy(agent.messages), agent.history_revision
        @test compact!(agent) == failure
        @test agent.messages == original
        @test agent.history_revision == revision
        @test !agent.running
    end

    agent = compactagent(CompactProvider(nothing, Any[]); history=CompactHistory.Memory())
    original = deepcopy(agent.messages)
    @test_throws DomainError compact!(agent, _ -> sqrt(-1))
    @test agent.messages == original
    @test !agent.running
    @test compact!(agent, _ -> begin
        @test compact!(agent, _ -> "nested") == :busy
        JuliaForever.steer!(agent, "queued")
        "stale"
    end) == CompactHistory.Rejected(:revision)
    @test agent.messages == original
    @test agent.state.steering == ["queued"]
    @test !agent.running

    history = CompactHistory.Memory()
    agent = compactagent(CompactProvider(nothing, Any[]); history)
    other = Agent(agent.provider, []; history)
    original = deepcopy(agent.messages)
    @test compact!(agent, _ -> (JuliaForever.steer!(other, "other writer"); "stale")) == CompactHistory.Rejected(:revision)
    @test agent.messages == original
    @test agent.fault == CompactHistory.Rejected(:revision)
    @test Agent(agent.provider, []; history).state.steering == ["other writer"]

    cancelled = compactagent(CompactProvider(nothing, Any[]))
    original = deepcopy(cancelled.messages)
    @test compact!(cancelled, _ -> (cancel!(cancelled); "cancelled summary")) == :cancelled
    @test cancelled.messages == original
    @test !cancelled.running
end

@testset "terminal command uses the configured provider" begin
    provider = CompactProvider(Dict{String, Any}("role" => "assistant", "content" => "provider checkpoint"), Any[])
    history = CompactHistory.Memory()
    agent = compactagent(provider; history)
    diagnostics = IOBuffer()
    terminal = JuliaForever.Terminal(IOBuffer(), diagnostics, String[])
    _, _, status = JuliaForever.command!(JuliaForever.terminalcommands["/compact"], terminal, agent, history, IOBuffer(), "", nothing)
    @test status == 0
    @test occursin("Context compacted.", String(take!(diagnostics)))
    @test isempty(only(provider.requests).tools)
    @test occursin("first answer", only(provider.requests).messages[1]["content"])
    @test !occursin("second answer", only(provider.requests).messages[1]["content"])
    @test agent.messages[2]["content"] == JuliaForever.summaryprefix * "provider checkpoint" * JuliaForever.summarysuffix
    @test Agent(provider, []; history).messages == agent.messages
end
