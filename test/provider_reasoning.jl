using Test, JuliaForever, HTTP, JSON3

@testset "streamed reasoning fields" begin
    streams = [
        [Dict("reasoning_content" => "", "reasoning" => "", "reasoning_text" => "α😀"), Dict("reasoning_content" => " B", "reasoning" => "duplicate", "reasoning_text" => "duplicate"), Dict("reasoning" => " C"), Dict("reasoning_text" => " D")],
        [Dict("reasoning_content" => "first", "reasoning" => "duplicate", "reasoning_text" => "duplicate")],
        [Dict("reasoning_content" => nothing, "reasoning" => "", "reasoning_text" => "fallback")],
        [Dict("content" => "without reasoning")],
    ]
    expected = [("reasoning_text", "α😀 B C D"), ("reasoning_content", "first"), ("reasoning_text", "fallback"), (nothing, nothing)]
    bodies = Channel{String}(length(streams))
    for chunks in streams
        body = join(sse(Dict("choices" => [Dict("index" => 0, "delta" => delta, "finish_reason" => nothing)])) for delta in chunks) * sse((; choices=[(; index=0, delta=(;), finish_reason="stop")])) * "data: [DONE]\n\n"
        put!(bodies, body)
    end
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], take!(bodies))
    end
    try
        model = OpenAI("http://$(HTTP.server_addr(server))/v1", "test", "synthetic")
        for (index, (field, text)) in enumerate(expected)
            events = []
            result = JuliaForever.stream(model, [], Dict(); on_event=event -> push!(events, event))
            @test result.done
            @test isnothing(field) || get(result.message, field, nothing) == text
            @test [key for key in ("reasoning_content", "reasoning", "reasoning_text") if haskey(result.message, key)] == (isnothing(field) ? [] : [field])
            native = JuliaForever.Conversation.Assistant(get(result.message, "content", nothing), JuliaForever.Conversation.ToolCall[], result.finish, result.done; metadata=result.message)
            @test ContextEstimates.tokens(native) == ContextEstimates.tokens(something(result.message["content"], "") * something(text, ""))
            if index == 1
                thinking = [event for event in events if event.type == :thinking]
                @test [event.field for event in thinking] == ["reasoning_text", "reasoning_content", "reasoning", "reasoning_text"]
                @test [event.text for event in thinking] == ["α😀", " B", " C", " D"]
            end
        end
    finally
        close(server)
        wait(server)
        close(bodies)
    end
end

@testset "streamed reasoning history and requests" begin
    requests = Any[]
    first = [
        Dict("choices" => [Dict("delta" => Dict("reasoning" => "draft", "reasoning_text" => "duplicate"), "finish_reason" => nothing)]),
        Dict("choices" => [Dict("delta" => Dict("reasoning_content" => " plus"), "finish_reason" => nothing)]),
        Dict("choices" => [Dict("delta" => Dict("tool_calls" => [Dict("index" => 0, "id" => "call-reasoning", "function" => Dict("name" => "write", "arguments" => "{\"path\":\"note.txt\",\"content\":\"ok\"}"))]), "finish_reason" => "tool_calls")]),
    ]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        push!(requests, JSON3.read(String(request.body)))
        chunks = length(requests) == 1 ? first : [(; choices=[(; delta=(; content="done"), finish_reason="stop")])]
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], join(sse.(chunks)) * "data: [DONE]\n\n")
    end
    try
        mktempdir() do dir
            path = joinpath(dir, "history.sqlite")
            provider = OpenAI("http://$(HTTP.server_addr(server))/v1", "test", "synthetic")
            history = open(JuliaForever.History.SQLite, path)
            agent = Agent(provider, [Write(dir)]; history)
            @test respond!(agent, "write it"; on_event=identity) == "done"
            @test read(joinpath(dir, "note.txt"), String) == "ok"
            @test length(requests) == 2
            first_message = agent.state.messages[2]
            @test get(first_message.metadata, "reasoning", nothing) == "draft plus"
            @test ContextEstimates.tokens(first_message) == ContextEstimates.tokens("draft pluswrite{\"path\":\"note.txt\",\"content\":\"ok\"}")
            @test get(agent.messages[2], "reasoning", nothing) == "draft plus"
            followup = requests[2].messages[2]
            @test get(followup, :reasoning, nothing) == "draft plus"
            @test !haskey(followup, :reasoning_content)
            @test !haskey(followup, :reasoning_text)
            @test followup.tool_calls[1].id == "call-reasoning"
            @test requests[2].messages[3].tool_call_id == "call-reasoning"
            close(history)

            history = open(JuliaForever.History.SQLite, path)
            restored = Agent(provider, [Write(dir)]; history)
            @test get(restored.state.messages[2].metadata, "reasoning", nothing) == "draft plus"
            replay = last(collect(JuliaForever.Kernel.Replay(restored.initial, restored.events))).state
            @test get(replay.messages[2].metadata, "reasoning", nothing) == "draft plus"
            @test JuliaForever.Kernel.same(replay.messages, restored.state.messages)
            @test respond!(restored, "continue"; on_event=identity) == "done"
            @test get(requests[3].messages[2], :reasoning, nothing) == "draft plus"
            @test !haskey(requests[3].messages[2], :reasoning_content)
            close(history)
        end
    finally
        close(server)
        wait(server)
    end
end

@testset "interrupted streamed reasoning" begin
    chunk = sse((; choices=[(; delta=(; reasoning_content="partial"), finish_reason=nothing)]))
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], chunk)
    end
    try
        history = JuliaForever.History.Memory()
        agent = Agent(OpenAI("http://$(HTTP.server_addr(server))/v1", "test", "synthetic"), []; history)
        result = respond!(agent, "start"; on_event=identity)
        @test !result.done
        @test get(result.message, "reasoning_content", nothing) == "partial"
        @test all(message -> !(message isa JuliaForever.Conversation.Assistant), agent.state.messages)
        @test occursin("partial", JSON3.write(collect(JuliaForever.History.snapshot(history))))
    finally
        close(server)
        wait(server)
    end
end
