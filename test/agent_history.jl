using Test, JuliaForever, JSON3
import JuliaForever.History as H
import JuliaForever.Durable as D
import JuliaForever.Conversation as C
import JuliaForever.Kernel as K

@testset "recorded incomplete streams and cancellation" begin
    provider = AgentFixture([completion("partial"; finish="content_filter", done=false)], [])
    history = H.Memory()
    agent = Agent(provider, []; history)
    events = Symbol[]
    result = respond!(agent, "start"; on_event=identity, on_agent_event=event -> push!(events, event.type))
    @test result isa Completion && !result.done
    @test result.message["content"] == "partial"
    @test agent.state.phase == C.Incomplete
    @test events == [:agent_start, :turn_start, :message_start, :message_end, :message_start, :message_update, :message_end, :turn_end, :agent_end]
    @test Agent(provider, []; history).state.phase == C.Incomplete
    @test length(provider.requests) == 1

    provider = Scripted([Dict("role" => "assistant", "content" => "unused")], [])
    agent = Agent(provider, []; history=H.Memory())
    result = respond!(agent, "cancel before dispatch"; on_agent_event=event -> begin
        event.type == :message_end && event.message["role"] == "user" && cancel!(agent)
    end)
    @test result == :cancelled
    @test isempty(provider.requests)

    provider = AgentFixture([completion("partial"; finish="content_filter", done=false)], [])
    agent = Agent(provider, []; history=H.Memory())
    result = respond!(agent, "cancel during stream"; on_event=identity, on_agent_event=event -> begin
        event.type == :message_update && cancel!(agent)
    end)
    @test result == :cancelled
    @test length(provider.requests) == 1
end

struct FailHistory{T} <: H.Store
    store::H.Memory
end
FailHistory(store::H.Memory, ::Type{T}) where T = FailHistory{T}(store)
H.snapshot(history::FailHistory) = H.snapshot(history.store)
function H.append!(history::FailHistory{T}, revision::Integer, batch::Vector) where T
    H.decode_event(only(batch)) isa T && return H.Rejected(:failed)
    H.append!(history.store, revision, batch)
end

struct UncertainHistory <: H.Store
    store::H.Memory
end
H.snapshot(history::UncertainHistory) = H.snapshot(history.store)
function H.append!(history::UncertainHistory, revision::Integer, batch::Vector)
    result = H.append!(history.store, revision, batch)
    revision == 0 && return result
    error("connection lost after append")
end

@testset "uncertain append stops the agent" begin
    history = UncertainHistory(H.Memory())
    agent = Agent(Scripted([], []), []; history)
    @test_throws ErrorException respond!(agent, "start")
    @test agent.fault == H.Rejected(:uncertain)
    @test respond!(agent, "again") == H.Rejected(:uncertain)
    @test H.snapshot(history).revision == 2
end

@testset "recorded agent and passive replay" begin
    mktempdir() do dir
        call = Dict{String, Any}("id" => "one", "type" => "function", "function" => Dict("name" => "write", "arguments" => "{\"path\":\"a.txt\",\"content\":\"safe\"}"))
        metadata = Dict{String, Any}("response_output" => Any[Dict{String, Any}("encrypted_content" => "opaque", "score" => -0.0, "details" => Dict("ok" => true)), call])
        first = Dict{String, Any}("role" => "assistant", "content" => nothing, "tool_calls" => [call], "response_output" => metadata["response_output"])
        provider = Scripted([first, Dict("role" => "assistant", "content" => "done")], [])
        history = H.Memory()
        agent = Agent(provider, [Write(dir)]; history)
        @test respond!(agent, "start") == "done"
        @test read(joinpath(dir, "a.txt"), String) == "safe"
        @test length(provider.requests) == 2
        @test isequal(provider.requests[2][2]["response_output"], metadata["response_output"])
        rm(joinpath(dir, "a.txt"))
        restored = Agent(provider, [Write(dir)]; history)
        @test restored.state.phase == C.Complete
        @test restored.state.revision == agent.state.revision
        @test isequal([H.encode(event) for event in restored.events], [H.encode(event) for event in agent.events])
        @test K.same(restored.state.messages[2].metadata, agent.state.messages[2].metadata)
        replay = K.Replay(restored.initial, restored.events)
        @test last(collect(replay)).state.phase == agent.state.phase
        @test last(collect(replay)).state.revision == agent.state.revision
        @test length(provider.requests) == 2
        @test !isfile(joinpath(dir, "a.txt"))
    end
end

@testset "failed and stale appends stop execution" begin
    provider = Scripted([Dict("role" => "assistant", "content" => "done")], [])
    history = H.Memory()
    agent = Agent(provider, []; history)
    @test H.append!(history, 1, Any["racing writer"]) == 2
    result = respond!(agent, "stale")
    @test result == H.Rejected(:revision)
    @test agent.state.revision == 0
    @test isempty(agent.events)
    @test isempty(provider.requests)
    @test respond!(agent, "again") == H.Rejected(:revision)

    mktempdir() do dir
        call = Dict{String, Any}("id" => "one", "type" => "function", "function" => Dict("name" => "write", "arguments" => "{\"path\":\"a.txt\",\"content\":\"unsafe\"}"))
        provider = Scripted([Dict{String, Any}("role" => "assistant", "content" => nothing, "tool_calls" => [call])], [])
        store = H.Memory()
        history = FailHistory(store, K.Observe{C.ModelReply})
        agent = Agent(provider, [Write(dir)]; history)
        @test respond!(agent, "start") == H.Rejected(:failed)
        @test agent.state.phase == C.WaitingModel
        @test length(provider.requests) == 1
        @test !isfile(joinpath(dir, "a.txt"))
        restored = Agent(provider, [Write(dir)]; history=store)
        @test restored.state.phase == C.WaitingModel
        @test respond!(restored, "again") == H.Rejected(:uncertain_effect)
        @test length(provider.requests) == 1
        @test JuliaForever.abandon!(restored, "inspected") isa K.Applied
        @test restored.state.phase == C.Incomplete
    end
end

@testset "unsupported provider metadata is an explicit boundary" begin
    provider = Scripted([Dict{String, Any}("role" => "assistant", "content" => "done", "opaque" => :unsupported)], [])
    history = H.Memory()
    agent = Agent(provider, []; history)
    @test respond!(agent, "start") == H.Rejected(:unsupported_value)
    @test agent.state.phase == C.WaitingModel
    @test length(provider.requests) == 1
    restored = Agent(provider, []; history)
    @test respond!(restored, "again") == H.Rejected(:uncertain_effect)
end

@testset "legacy behavior remains opt out" begin
    provider = Scripted([Dict("role" => "assistant", "content" => "done")], [])
    agent = Agent(provider, [])
    @test respond!(agent, "start") == "done"
    @test agent.state.phase == C.Complete
end

mutable struct KeyedProvider
    key::String
    calls::Int
end
function JuliaForever.complete(provider::KeyedProvider, messages, tools)
    provider.calls += 1
    Dict{String, Any}("role" => "assistant", "content" => "done")
end

@testset "history contains data, never the provider" begin
    provider = KeyedProvider("synthetic-secret-not-history", 0)
    history = H.Memory()
    agent = Agent(provider, []; history)
    @test respond!(agent, "hello") == "done"
    @test !occursin(provider.key, repr(collect(H.snapshot(history))))
    @test provider.calls == 1
end

@testset "codec validates versions and typed data" begin
    metadata = Dict{String, Any}("output" => Any[Dict{String, Any}("encrypted_content" => "opaque", "nested" => Dict("valid" => true), "values" => [1, 2], "negative_zero" => -0.0)])
    call = C.ToolCall("id", "name", "{}"; metadata)
    answer = C.Assistant(nothing, [call], "tool_calls", true; metadata)
    events = K.Event[C.Input(0, "hello"), C.Steer(1, "later"), C.Followup(2, "after"), C.Advance(3), C.Cancel(4), C.History(5, C.Message[C.User("x"), C.RawMessage(Dict{String, Any}("meta" => metadata))]), C.Interrupt(6, "halt"), K.Observe(7, "effect", C.ModelReply(answer)), K.Observe(8, "tool", C.ToolReply("yes", false)), K.Observe(9, "model", C.ModelFailure("offline")), K.Observe(10, "model", C.Abandoned("unknown")), K.Plan(0, "call", K.Call("run", metadata)), K.Observe(1, "call", K.Return(metadata)), K.Observe(1, "call", K.Fail(metadata)), K.Finish(2)]
    for event in events
        record = H.encode(event)
        decoded = H.decode_event(record)
        @test typeof(decoded) === typeof(event)
        @test isequal(H.encode(decoded), record)
    end
    @test H.decode_event(Dict("format" => "JuliaForever.AgentEvent/2")) == H.Rejected(:invalid_record)
    @test H.decode_event(Dict("format" => "JuliaForever.AgentEvent/1", "event" => Dict("kind" => "observe", "fields" => Any[0]))) == H.Rejected(:invalid_record)
    @test H.encode(K.Observe(0, "x", K.Return((a=1,)))) == H.Rejected(:unsupported_value)
    @test H.typecode(Vector{Vector{Int}}) == Any["vector", Any["vector", "int"]]
    @test H.typecode(Vector{Tuple{Int}}) == H.Rejected(:unsupported_value)
    @test H.valuetype(Any["vector", Any["dict", "int"]]) === Vector{Dict{String, Int}}
    @test H.valuetype(Any["vector", "unknown"]) == H.Rejected(:invalid_record)
    @test H.packall(C.Message[C.User("first"), C.RawMessage(Dict{String, Any}("bad" => (a=1,))), C.User("last")]) == H.Rejected(:unsupported_value)
    nodes = Any[
        C.User("hi"), C.RawMessage(Dict{String, Any}("text" => "hello")), call, answer,
        C.ToolMessage("id", "result", false), C.ModelRequest(C.Message[C.User("hi")]),
        C.ToolRequest(call), C.SkipRequest(call), C.ModelReply(answer), C.ToolReply("ok", false),
        C.ModelFailure("failed"), C.Abandoned("reason"), C.Input(0, "input"), C.Steer(1, "steer"),
        C.Followup(2, "followup"), C.Dequeue(3), C.SessionName(3, "name"), C.Advance(3), C.Cancel(4), C.History(5, C.Message[C.User("hi")]),
        C.Interrupt(6, "interrupted"), C.Abandon(7, "abandon"), K.Call("read", Dict("x" => 1)),
        K.Return(1), K.Fail("bad"), K.Plan(0, "id", K.Call("read", 1)),
        K.Observe(1, "id", K.Return(2)), K.Finish(2),
    ]
    for node in nodes
        encoded = H.pack(node)
        @test isequal(H.pack(H.unpack(encoded)), encoded)
    end
    @test H.unpack(Dict("kind" => "unknown", "fields" => Any[])) == H.Rejected(:invalid_record)
    @test H.unpack(Dict("kind" => "tool_reply", "fields" => "bad")) == H.Rejected(:invalid_record)
    @test H.unvalue(Dict("kind" => "vector", "type" => "int", "items" => Dict())) == H.Rejected(:invalid_record)
end

@testset "planning and tool observation failures are boundaries" begin
    provider = KeyedProvider("secret", 0)
    store = H.Memory()
    agent = Agent(provider, []; history=FailHistory(store, C.Advance))
    @test respond!(agent, "hello") == H.Rejected(:failed)
    @test agent.state.phase == C.ReadyModel
    @test provider.calls == 0
    @test respond!(Agent(provider, []; history=store), "again") == H.Rejected(:incomplete_turn)

    mktempdir() do dir
        calls = [Dict{String, Any}("id" => string(i), "type" => "function", "function" => Dict("name" => "write", "arguments" => "{\"path\":\"$(i).txt\",\"content\":\"written\"}")) for i in 1:2]
        provider = Scripted([Dict{String, Any}("role" => "assistant", "content" => nothing, "tool_calls" => calls)], [])
        store = H.Memory()
        agent = Agent(provider, [Write(dir)]; history=FailHistory(store, K.Observe{C.ToolReply}))
        @test respond!(agent, "go"; tool_execution=:sequential) == H.Rejected(:failed)
        @test isfile(joinpath(dir, "1.txt"))
        @test !isfile(joinpath(dir, "2.txt"))
        @test length(provider.requests) == 1
        @test agent.state.phase == C.WaitingTools
        restored = Agent(provider, [Write(dir)]; history=store)
        @test respond!(restored, "again") == H.Rejected(:uncertain_effect)
        @test length(restored.state.kernel.pending) == 2
    end
end

@testset "durable history reopens without replaying an interrupted effect" begin
    if Sys.isunix()
        mktempdir() do dir
            path = joinpath(dir, "history.jsonl")
            marker = joinpath(dir, "effect.txt")
            store = open(D.Store, path)
            history = H.create(store)
            id = history.id
            close(store)
            script = """
                using JuliaForever
                import JuliaForever.History as H
                import JuliaForever.Durable as D
                struct Provider end
                function JuliaForever.complete(::Provider, messages, tools)
                    call = Dict{String, Any}(\"id\" => \"one\", \"type\" => \"function\", \"function\" => Dict(\"name\" => \"die\", \"arguments\" => \"{}\"))
                    Dict{String, Any}(\"role\" => \"assistant\", \"content\" => nothing, \"tool_calls\" => [call])
                end
                struct Die <: JuliaForever.Tool
                    marker::String
                end
                JuliaForever.name(::Die) = \"die\"
                function JuliaForever.execute(tool::Die, args)
                    write(tool.marker, \"effect ran\")
                    exit(17)
                end
                store = open(D.Store, ARGS[1])
                history = H.Journal(store, parse(Int, ARGS[2]))
                agent = Agent(Provider(), [Die(ARGS[3])]; history)
                respond!(agent, \"start\")
                exit(19)
            """
            project = dirname(@__DIR__)
            process = run(ignorestatus(`$(Base.julia_cmd()) --compiled-modules=no --project=$project -e $script $path $id $marker`))
            @test process.exitcode == 17
            @test read(marker, String) == "effect ran"
            store = open(D.Store, path)
            history = H.Journal(store, id)
            provider = KeyedProvider("secret", 0)
            restored = Agent(provider, []; history)
            @test restored.state.phase == C.WaitingTools
            @test respond!(restored, "next") == H.Rejected(:uncertain_effect)
            @test provider.calls == 0
            @test JuliaForever.abandon!(restored, "effect inspected") isa K.Applied
            close(store)
            store = open(D.Store, path)
            reopened = Agent(provider, []; history=H.Journal(store, id))
            @test reopened.state.phase == C.Incomplete
            @test respond!(reopened, "new turn") == "done"
            @test provider.calls == 1
            close(store)
        end
    end
end

@testset "callback conflicts cannot dispatch" begin
    history = H.Memory()
    provider = KeyedProvider("secret", 0)
    agent = Agent(provider, []; history)
    failures = Any[]
    result = respond!(agent, "start"; on_agent_event=event -> begin
        if event.type == :agent_start
            @test H.append!(history, 1, Any["other writer"]) == 2
            push!(failures, JuliaForever.steer!(agent, "too late"))
        end
    end)
    @test failures == [H.Rejected(:revision)]
    @test result == H.Rejected(:revision)
    @test agent.state.revision == 0
    @test provider.calls == 0
end

@testset "existing histories do not discard supplied messages" begin
    history = H.Memory()
    provider = KeyedProvider("secret", 0)
    @test Agent(provider, []; history) isa Agent
    messages = Dict{String, Any}[Dict("role" => "system", "content" => "do not discard")]
    @test Agent(provider, Dict{String, JuliaForever.Tool}(), messages; history) == H.Rejected(:history_exists)
    @test H.snapshot(history).revision == 1
end

@testset "a stale tool plan is never dispatched" begin
    mktempdir() do dir
        call = Dict{String, Any}("id" => "one", "type" => "function", "function" => Dict("name" => "write", "arguments" => "{\"path\":\"a.txt\",\"content\":\"unsafe\"}"))
        provider = Scripted([Dict{String, Any}("role" => "assistant", "content" => nothing, "tool_calls" => [call])], [])
        history = H.Memory()
        agent = Agent(provider, [Write(dir)]; history)
        result = respond!(agent, "start"; on_agent_event=event -> begin
            if event.type == :tool_execution_start
                revision = H.snapshot(history).revision
                @test H.append!(history, revision, Any["other writer"]) == revision + 1
                @test JuliaForever.steer!(agent, "too late") == H.Rejected(:revision)
            end
        end)
        @test result == H.Rejected(:revision)
        @test agent.state.phase == C.WaitingTools
        @test !isfile(joinpath(dir, "a.txt"))
    end
end

@testset "recording a parsed Responses payload preserves encrypted metadata" begin
    output = JSON3.read("""[{"type":"reasoning","id":"r","encrypted_content":"opaque","summary":[]},{"type":"message","id":"m","content":[{"type":"output_text","text":"done","annotations":[]}]}]""", Vector{Any})
    model = OpenAIResponses("https://unused.invalid", "fixture", "synthetic-private-key")
    reply = JuliaForever.completion(model, Dict{String, Any}("output" => output, "status" => "completed"))
    provider = Scripted([reply], [])
    history = H.Memory()
    agent = Agent(provider, []; history)
    @test respond!(agent, "start") == "done"
    restored = Agent(provider, []; history)
    message = last(restored.state.messages)
    @test K.same(message.metadata["response_output"], output)
    @test message.metadata["response_output"][1]["encrypted_content"] == "opaque"
    @test !occursin("synthetic-private-key", repr(collect(H.snapshot(history))))
end

@testset "recorded callback steering and tool observations retain order" begin
    mktempdir() do dir
        calls = [Dict{String, Any}("id" => string(i), "type" => "function", "function" => Dict("name" => "write", "arguments" => "{\"path\":\"$(i).txt\",\"content\":\"$(i)\"}")) for i in 1:2]
        provider = Scripted([Dict{String, Any}("role" => "assistant", "content" => nothing, "tool_calls" => calls), Dict{String, Any}("role" => "assistant", "content" => "done")], [])
        history = H.Memory()
        agent = Agent(provider, [Write(dir)]; history)
        @test respond!(agent, "start"; on_agent_event=event -> begin
            event.type == :tool_execution_start && event.tool_call_id == "1" && JuliaForever.steer!(agent, "steer")
        end) == "done"
        @test [message["tool_call_id"] for message in provider.requests[2] if message["role"] == "tool"] == ["1", "2"]
        @test [message["content"] for message in provider.requests[2] if message["role"] == "user"] == ["start", "steer"]
        observations = [event for event in agent.events if event isa K.Observe && event.observation isa C.ToolReply]
        @test length(observations) == 2
        @test [event.id for event in observations] == [item.id for item in agent.state.kernel.observations if item.observation isa C.ToolReply]
        restored = Agent(provider, [Write(dir)]; history)
        @test [message.id for message in restored.state.messages if message isa C.ToolMessage] == ["1", "2"]
        @test [event.id for event in restored.events if event isa K.Observe && event.observation isa C.ToolReply] == [event.id for event in observations]
    end
end

struct BrokenHistoryProvider end
JuliaForever.complete(::BrokenHistoryProvider, messages, tools) = error("provider disconnected")

@testset "recorded failures expose uncertainty" begin
    history = H.Memory()
    agent = Agent(BrokenHistoryProvider(), []; history)
    @test respond!(agent, "start"; tool_execution=:unknown) == H.Rejected(:unsupported_execution)
    @test H.snapshot(history).revision == 1
    @test_throws ErrorException respond!(agent, "start")
    @test respond!(agent, "again") == H.Rejected(:uncertain_effect)
    restored = Agent(KeyedProvider("secret", 0), []; history)
    @test respond!(restored, "again") == H.Rejected(:uncertain_effect)
end

@testset "recorded custom streamed completion states" begin
    message = Dict{String, Any}("role" => "assistant", "content" => "answer")
    complete = CustomCompletion(message, "stop", true)
    @test respond!(Agent(CustomStreaming(complete), []; history=H.Memory()), "start"; on_event=identity) == "answer"
    partial = CustomCompletion(message, "incomplete", false)
    history = H.Memory()
    agent = Agent(CustomStreaming(partial), []; history)
    @test respond!(agent, "start"; on_event=identity) === partial
    @test Agent(CustomStreaming(partial), []; history).state.phase == C.Incomplete
end
