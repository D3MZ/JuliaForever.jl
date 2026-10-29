using Test, JSON3, JuliaForever

import JuliaForever.Logs as L

mutable struct OnceHistory{T}
    items::T
    started::Bool
end

@testset "conversation history export" begin
    C = JuliaForever.Conversation
    K = JuliaForever.Kernel
    start = C.State("session")
    input = C.Input(0, "read")
    requested = K.step(start, input)
    call = C.ToolCall("c1", "read", "{\"path\":\"a.txt\"}")
    metadata = Dict("response_output" => [Dict("type" => "reasoning", "encrypted_content" => "cipher")])
    answer = C.Assistant(nothing, [call], "tool_calls", true; metadata)
    model = K.Observe(1, only(requested.effects).id, C.ModelReply(answer))
    tools = K.step(requested.state, model)
    result = K.Observe(2, only(tools.effects).id, C.ToolReply("text", false))
    events = K.Event[input, model, result]
    exported = JSON3.read(L.json(events))
    @test [row.type for row in exported] == ["input", "observe", "observe"]
    @test exported[2].observation.type == "model_reply"
    @test exported[3].observation.type == "tool_reply"
    @test exported[2].observation.message.metadata.response_output[1].encrypted_content == "cipher"
    replay = JSON3.read(L.json(K.Replay(start, events)))
    @test replay[2].state.phase == "WaitingTools"
    @test replay[2].effects[1].effect.type == "tool_request"
    @test replay[3].state.messages[end].content == "text"
    @test occursin("cipher", L.html(K.Replay(start, events)))
end

Base.IteratorSize(::Type{<:OnceHistory}) = Base.SizeUnknown()
Base.IteratorEltype(::Type{<:OnceHistory}) = Base.EltypeUnknown()
function Base.iterate(history::OnceHistory)
    history.started && error("history was iterated more than once")
    history.started = true
    iterate(history.items)
end
Base.iterate(history::OnceHistory, state) = iterate(history.items, state)

@testset "history export" begin
    danger = "</pre><script>alert(\"hi & 'there'\")</script> café"
    history = [
        (; type="start", revision=0, text="hello"),
        (; type="update", revision=1, text=danger, details=(; nested=[1, 2])),
        (; type="end", revision=2, result=nothing),
    ]
    json = L.json(OnceHistory(history, false))
    decoded = JSON3.read(json)
    @test length(decoded) == 3
    @test [event.type for event in decoded] == ["start", "update", "end"]
    @test decoded[2].text == danger
    @test collect(decoded[2].details.nested) == [1, 2]
    @test decoded[3].result === nothing

    io = IOBuffer()
    L.json(io, OnceHistory(history, false))
    @test String(take!(io)) == json

    html = L.html(OnceHistory(history, false); title="<unsafe & title>")
    @test occursin("<!doctype html>", lowercase(html))
    @test occursin("&lt;unsafe &amp; title&gt;", html)
    @test !occursin("<unsafe", html)
    @test !occursin("<script>", html)
    @test !occursin("</pre><script>", html)
    @test occursin("&lt;/pre&gt;&lt;script&gt;", html)
    @test occursin("&amp;", html)
    @test occursin("&#39;", html)
    @test occursin("&quot;", html)
    @test occursin("café", html)
    @test length(collect(eachmatch(r"<li><pre>", html))) == 3
    rows = [replace(match.captures[1], "&lt;" => "<", "&gt;" => ">", "&quot;" => "\"", "&#39;" => "'", "&amp;" => "&") for match in eachmatch(r"<li><pre>(.*?)</pre></li>"s, html)]
    viewed = JSON3.read.(rows)
    @test [event.type for event in viewed] == [event.type for event in decoded]
    @test viewed[2].text == danger
    @test collect(viewed[2].details.nested) == [1, 2]
    @test viewed[3].result === nothing

    io = IOBuffer()
    L.html(io, OnceHistory(history, false); title="<unsafe & title>")
    @test String(take!(io)) == html

    @test JSON3.read(L.json(OnceHistory((), false))) == []
    emptyhtml = L.html(OnceHistory((), false))
    @test occursin("No events.", emptyhtml)
    @test !occursin("<li><pre>", emptyhtml)

    calls = Ref(0)
    project = event -> begin
        calls[] += 1
        (; n=event.revision)
    end
    @test [event.n for event in JSON3.read(L.json(history; project))] == [0, 1, 2]
    @test calls[] == 3
    calls[] = 0
    @test length(collect(eachmatch(r"<li><pre>", L.html(history; project)))) == 3
    @test calls[] == 3
end

import JuliaForever.Kernel as K

struct LogMarker <: K.Effect
    path::String
end

(marker::LogMarker)() = write(marker.path, "effect ran")
L.record(marker::LogMarker) = (; type="marker", path=marker.path)

@testset "kernel history export" begin
    mktempdir() do dir
        path = joinpath(dir, "not-created.txt")
        message = "</pre><script>danger & detail</script>"
        events = K.Event[
            K.Plan(0, "write-1", K.Call("write", (; path, message))),
            K.Observe(1, "write-1", K.Return((; text=message))),
            K.Plan(2, "marker-1", LogMarker(path)),
            K.Observe(3, "marker-1", K.Fail("denied")),
            K.Finish(4),
        ]
        records = JSON3.read(L.json(events))
        @test [record.type for record in records] == ["plan", "observe", "plan", "observe", "finish"]
        @test records[1].revision == 0
        @test records[1].id == "write-1"
        @test records[1].effect.type == "call"
        @test records[1].effect.name == "write"
        @test records[1].effect.input.path == path
        @test records[1].effect.input.message == message
        @test records[2].observation.type == "return"
        @test records[2].observation.value.text == message
        @test records[3].effect.type == "marker"
        @test records[3].effect.path == path
        @test records[4].observation.type == "fail"
        @test records[4].observation.value == "denied"
        @test records[end].revision == 4

        replay = K.Replay(K.State("conversation-1"), events)
        results = JSON3.read(L.json(replay))
        @test length(results) == 5
        @test all(result -> result.type == "applied", results)
        @test [result.state.revision for result in results] == [1, 2, 3, 4, 5]
        @test results[1].state.id == "conversation-1"
        @test results[1].state.pending[1].id == "write-1"
        @test results[1].state.pending[1].effect.input.message == message
        @test results[1].effects[1].effect.name == "write"
        @test results[2].state.observations[1].observation.value.text == message
        @test results[3].effects[1].effect.type == "marker"
        @test results[end].state.closed
        @test isempty(results[end].state.pending)
        @test length(results[end].state.observations) == 2
        @test !isfile(path)

        html = L.html(replay)
        @test length(collect(eachmatch(r"<li><pre>", html))) == 5
        @test occursin("&lt;/pre&gt;&lt;script&gt;", html)
        @test !occursin("<script>", html)
        @test !isfile(path)

        retry = K.Replay(K.State("retry"), (events[1], events[2], events[2], K.Finish(2)))
        retried = JSON3.read(L.json(retry))
        @test [result.type for result in retried] == ["applied", "applied", "duplicate", "applied"]
        @test retried[3].state.revision == 2
        rejected = K.Replay(K.State("reject"), (events[1], K.Finish(1), events[2]))
        failed = JSON3.read(L.json(rejected))
        @test [result.type for result in failed] == ["applied", "rejected"]
        @test failed[end].reason == "pending"
        @test failed[end].state.revision == 1
        @test !isfile(path)
    end
end
