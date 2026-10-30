using HTTP, JSON3

response_sse(data) = "data: $(JSON3.write(data))\n\n"
response_call(id, call, path, content) = Dict("type" => "function_call", "id" => id, "call_id" => call, "name" => "write", "arguments" => JSON3.write((; path, content)), "status" => "completed")
response_text(text) = Dict("type" => "message", "id" => "msg_1", "status" => "completed", "role" => "assistant", "content" => [Dict("type" => "output_text", "text" => text, "annotations" => [])])
@testset "Responses call validation" begin
    call = response_call("id", "call", "file", "content")
    @test JuliaForever.callfailure([call], nothing) === nothing
    nostatus = copy(call)
    delete!(nostatus, "status")
    @test JuliaForever.callfailure([nostatus], nothing) === nothing
    @test JuliaForever.callfailure([merge(call, Dict("status" => "running"))], nothing) == "Responses contained an unfinished function call"
    for key in ("id", "call_id", "name", "arguments"), value in (nothing, "", 1)
        bad = merge(call, Dict(key => value))
        @test JuliaForever.callfailure([bad], nothing) == "Responses contained an unfinished function call"
        @test JuliaForever.callfailure([bad], "earlier") == "earlier"
    end
    missing = copy(call)
    delete!(missing, "name")
    @test JuliaForever.callfailure([missing], nothing) == "Responses contained an unfinished function call"
    @test JuliaForever.callfailure([call, merge(call, Dict("call_id" => "other"))], nothing) == "Responses contained duplicate function call identifiers"
    @test JuliaForever.callfailure([call, merge(call, Dict("id" => "other"))], nothing) == "Responses contained duplicate function call identifiers"
end

response_reasoning() = Dict("type" => "reasoning", "id" => "rs_1", "summary" => [], "encrypted_content" => "synthetic-encrypted")
response_done(output; status="completed", usage=nothing) = Dict("id" => "resp_1", "status" => status, "output" => output, "usage" => usage)

@testset "Responses configuration" begin
    model = provider(Dict("JF_PROVIDER" => "openai-responses", "OPENAI_MODEL" => "gpt-6-astra", "OPENAI_API_KEY" => "synthetic", "OPENAI_BASE_URL" => "http://localhost/v1/", "PI_CODING_AGENT_DIR" => mktempdir()))
    @test model isa OpenAIResponses
    @test model.model == "gpt-6-astra"
    @test !occursin("synthetic", sprint(show, model))
    @test provider(Dict("OPENAI_MODEL" => "old", "OPENAI_API_KEY" => "synthetic", "PI_CODING_AGENT_DIR" => mktempdir())) isa OpenAI
end

@testset "Responses completion status and call validation" begin
    model = OpenAIResponses("http://localhost/v1", "fixture", "synthetic")
    call = response_call("fc_1", "call_1", "one.txt", "one")
    completed = JuliaForever.completion(model, response_done([call]))
    @test completed.done && completed.finish == "tool_calls" && completed.error === nothing
    text = JuliaForever.completion(model, response_done([response_text("answer")]))
    @test text.done && text.finish == "stop"
    for (status, kind) in (("failed", :failed), ("incomplete", :incomplete), (nothing, :unknown))
        result = JuliaForever.completion(model, response_done([call]; status))
        @test !result.done && result.finish === status
        @test result.error isa ProviderError && result.error.provider == :openai_responses && result.error.kind == kind
    end
    unfinished = merge(call, Dict("status" => "in_progress"))
    result = JuliaForever.completion(model, response_done([unfinished]))
    @test !result.done && result.error == "Responses contained an unfinished function call"
    duplicate = merge(call, Dict("id" => "fc_2"))
    result = JuliaForever.completion(model, response_done([call, duplicate]))
    @test !result.done && result.error == "Responses contained duplicate function call identifiers"
    result = JuliaForever.completion(model, response_done([unfinished]); failure="earlier failure")
    @test !result.done && result.error == "earlier failure"
end

@testset "Responses completion callbacks and reconciliation" begin
    model = OpenAIResponses("http://localhost/v1", "fixture", "synthetic")
    events = []
    state = JuliaForever.ResponseStream(event -> push!(events, event))
    result = JuliaForever.finish(model, state, response_done([response_text("ok")]; usage=Dict("input_tokens" => 2, "output_tokens" => 3)))
    @test result.done
    @test [event.type for event in events] == [:usage, :finish]
    @test events[1].usage.total == 5 && events[2].reason == "stop"

    empty!(events)
    result = JuliaForever.finish(model, JuliaForever.ResponseStream(event -> push!(events, event)), response_done([]; status=nothing))
    @test !result.done && isempty(events)

    call = response_call("fc_1", "call_1", "one.txt", "one")
    result = JuliaForever.finish(model, JuliaForever.ResponseStream(identity), response_done([call]))
    @test !result.done && occursin("mismatched function call", result.error)
end

@testset "Responses nonstreamed function loop and replay" begin
    requests = Any[]
    calls = [response_call("fc_1", "call_1", "a.txt", "first"), response_call("fc_2", "call_2", "b.txt", "second")]
    original = [response_reasoning(), calls...]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        push!(requests, (; target=request.target, auth=HTTP.header(request, "Authorization"), body=JSON3.read(String(request.body))))
        output = length(requests) == 1 ? original : [response_text("done")]
        HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(response_done(output)))
    end
    try
        mktempdir() do dir
            model = OpenAIResponses("http://$(HTTP.server_addr(server))/v1/", "gpt-6-astra", "synthetic-key")
            agent = Agent(model, [Write(dir)])
            @test respond!(agent, "write both"; parameters=Dict("model" => "ignored", "input" => ["ignored"], "messages" => ["ignored"], "stream" => true, "tools" => ["ignored"], "reasoning" => Dict("effort" => "low"))) == "done"
            @test read(joinpath(dir, "a.txt"), String) == "first"
            @test read(joinpath(dir, "b.txt"), String) == "second"
            @test length(requests) == 2
            first, second = requests
            @test first.target == "/v1/responses"
            @test first.auth == "Bearer synthetic-key"
            @test first.body.model == "gpt-6-astra"
            @test first.body.stream == false
            @test first.body.store == false
            @test "reasoning.encrypted_content" in first.body.include
            @test first.body.reasoning.effort == "low"
            @test !haskey(first.body, :messages)
            @test first.body.input[1].role == "user"
            @test first.body.tools[1].type == "function"
            @test first.body.tools[1].name == "write"
            @test first.body.tools[1].parameters.type == "object"
            @test first.body.tools[1].strict == false
            @test !haskey(first.body.tools[1], :function)
            @test second.body.input[2].type == "reasoning"
            @test second.body.input[2].encrypted_content == "synthetic-encrypted"
            @test second.body.input[3].id == "fc_1"
            @test second.body.input[3].call_id == "call_1"
            @test second.body.input[4].call_id == "call_2"
            @test second.body.input[5].type == "function_call_output"
            @test second.body.input[5].call_id == "call_1"
            @test second.body.input[5].output == "Successfully wrote to a.txt"
            @test second.body.input[6].call_id == "call_2"
        end
    finally
        close(server)
        wait(server)
    end
end

@testset "Responses streaming events and function loop" begin
    requests = Any[]
    waiting = Channel{Nothing}(1)
    acknowledged = Channel{Nothing}(1)
    call = response_call("fc_1", "call_1", "stream.txt", "streamed")
    args = call["arguments"]
    firstpart, secondpart = args[1:10], args[11:end]
    server = HTTP.listen!("127.0.0.1", 0; listenany=true) do io
        request = HTTP.startread(io)
        push!(requests, (; target=request.target, body=JSON3.read(String(read(io)))))
        HTTP.setheader(io, "Content-Type" => "text/event-stream")
        HTTP.startwrite(io)
        if length(requests) == 1
            write(io, response_sse((; type="response.reasoning_summary_text.delta", output_index=0, item_id="rs_1", delta="think")))
            write(io, response_sse((; type="response.output_item.added", output_index=1, item=Dict("type" => "function_call", "id" => "fc_1", "call_id" => "call_1", "name" => "write", "arguments" => ""))))
            write(io, response_sse((; type="response.function_call_arguments.delta", output_index=1, item_id="fc_1", delta=firstpart)))
            flush(io)
            put!(waiting, nothing)
            take!(acknowledged)
            write(io, response_sse((; type="response.function_call_arguments.delta", output_index=1, item_id="fc_1", delta=secondpart)))
            write(io, response_sse((; type="response.function_call_arguments.done", output_index=1, item_id="fc_1", arguments=args)))
            write(io, response_sse((; type="response.output_item.done", output_index=0, item=response_reasoning())))
            write(io, response_sse((; type="response.output_item.done", output_index=1, item=call)))
            write(io, response_sse((; type="response.completed", response=response_done([response_reasoning(), call]; usage=Dict("input_tokens" => 20, "output_tokens" => 5, "total_tokens" => 25, "input_tokens_details" => Dict("cached_tokens" => 4, "cache_write_tokens" => 2), "output_tokens_details" => Dict("reasoning_tokens" => 3))))))
        else
            write(io, response_sse((; type="response.output_text.delta", output_index=0, item_id="msg_1", content_index=0, delta="done")))
            write(io, response_sse((; type="response.output_item.done", output_index=0, item=response_text("done"))))
            write(io, response_sse((; type="response.completed", response=response_done([response_text("done")]))))
        end
    end
    try
        mktempdir() do dir
            agent = Agent(OpenAIResponses("http://$(HTTP.server_addr(server))/v1", "test", "synthetic"), [Write(dir)])
            events = []
            @test respond!(agent, "create"; on_event=event -> begin
                push!(events, event)
                if event.type == :tool_call && event.arguments == firstpart
                    take!(waiting)
                    put!(acknowledged, nothing)
                end
            end) == "done"
            @test read(joinpath(dir, "stream.txt"), String) == "streamed"
            @test length(requests) == 2
            @test all(request -> request.target == "/v1/responses" && request.body.stream, requests)
            @test requests[2].body.input[2].encrypted_content == "synthetic-encrypted"
            @test requests[2].body.input[end].call_id == "call_1"
            @test [event.text for event in events if event.type == :thinking] == ["think"]
            @test [event.arguments for event in events if event.type == :tool_call] == [firstpart, secondpart]
            @test [event.text for event in events if event.type == :text] == ["done"]
            u = only(event.usage for event in events if event.type == :usage)
            @test (u.input, u.output, u.cache_read, u.cache_write, u.reasoning, u.total) == (14, 5, 4, 2, 3, 25)
            @test count(event -> event.type == :done, events) == 2
            @test any(event -> event.type == :provider && event.data["type"] == "response.completed", events)
        end
    finally
        close(server)
        wait(server)
    end
end

@testset "Responses failure boundaries" begin
    call = response_call("fc_1", "call_1", "unsafe.txt", "must not run")
    started = Dict("type" => "response.output_item.added", "output_index" => 0, "item" => call)
    replies = [
        response_sse((; type="response.output_text.delta", output_index=0, item_id="msg_1", content_index=0, delta="partial")),
        response_sse((; type="response.failed", response=Dict("status" => "failed", "error" => Dict("message" => "capacity"), "output" => []))),
        response_sse(started) * response_sse((; type="response.completed", response=response_done([call]))),
        response_sse((; type="response.incomplete", response=Dict("status" => "incomplete", "incomplete_details" => Dict("reason" => "max_output_tokens"), "output" => [call]))),
        JSON3.write(Dict("status" => "incomplete", "incomplete_details" => Dict("reason" => "max_output_tokens"), "output" => [call]))
    ]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        content_type = length(replies) > 1 ? "text/event-stream" : "application/json"
        HTTP.Response(200, ["Content-Type" => content_type], popfirst!(replies))
    end
    try
        mktempdir() do dir
            model = OpenAIResponses("http://$(HTTP.server_addr(server))/v1", "test", "synthetic")
            partial = stream(model, [], Dict())
            @test !partial.done
            @test partial.message["content"] == "partial"
            failed = stream(model, [], Dict())
            @test !failed.done
            @test failed.error isa ProviderError && failed.error.provider == :openai_responses
            unfinished = respond!(Agent(model, [Write(dir)]), "create"; on_event=identity)
            @test !unfinished.done
            @test occursin("unfinished", unfinished.error)
            incomplete = respond!(Agent(model, [Write(dir)]), "create"; on_event=identity)
            @test !incomplete.done
            @test incomplete.error isa ProviderError && incomplete.error.kind == :max_output_tokens
            nonstream = respond!(Agent(model, [Write(dir)]), "create")
            @test !nonstream.done
            @test nonstream.error isa ProviderError && nonstream.error.kind == :max_output_tokens
            @test !isfile(joinpath(dir, "unsafe.txt"))
        end
    finally
        close(server)
        wait(server)
    end
end

@testset "Responses interleaved calls and terminal reconciliation" begin
    first = response_call("fc_1", "call_1", "one.txt", "one")
    second = response_call("fc_2", "call_2", "two.txt", "two")
    added(call, index) = (; type="response.output_item.added", output_index=index, item=merge(call, Dict("arguments" => "", "status" => "in_progress")))
    delta(call, index, text) = (; type="response.function_call_arguments.delta", output_index=index, item_id=call["id"], delta=text)
    done(call, index) = (; type="response.output_item.done", output_index=index, item=call)
    completed(output) = (; type="response.completed", response=response_done(output))
    streams = [
        response_sse(added(first, 0)) * response_sse(added(second, 1)) * response_sse(delta(second, 1, second["arguments"])) * response_sse(delta(first, 0, first["arguments"])) * response_sse(done(second, 1)) * response_sse(done(first, 0)) * response_sse(completed([first, second])),
        response_sse(done(first, 0)) * response_sse(completed([])),
        response_sse(done(first, 0)) * response_sse(completed([merge(first, Dict("arguments" => "{}"))])),
        response_sse(added(first, 0)) * response_sse(delta(first, 0, "{}") |> x -> merge(Dict(pairs(x)), Dict("item_id" => "fc_wrong"))) * response_sse(done(first, 0)) * response_sse(completed([first])),
        response_sse(done(first, 0)) * response_sse(done(merge(second, Dict("call_id" => "call_1")), 1)) * response_sse(completed([first, merge(second, Dict("call_id" => "call_1"))]))
    ]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], popfirst!(streams))
    end
    try
        model = OpenAIResponses("http://$(HTTP.server_addr(server))/v1", "test", "synthetic")
        events = []
        result = stream(model, [], Dict(); on_event=event -> push!(events, event))
        @test result.done
        @test [call["id"] for call in result.message["tool_calls"]] == ["call_1", "call_2"]
        @test [(event.id, event.index) for event in events if event.type == :tool_call] == [("call_2", 1), ("call_1", 0)]
        for _ in 1:4
            result = stream(model, [], Dict())
            @test !result.done
            @test result.error isa AbstractString
        end
    finally
        close(server)
        wait(server)
    end
end

@testset "Responses streamed reasoning replay" begin
    reasoning = response_reasoning()
    final_reasoning = Dict("type" => "reasoning", "id" => "rs_1", "summary" => [])
    payload = response_sse((; type="response.output_item.done", output_index=0, item=reasoning)) * response_sse((; type="response.output_item.done", output_index=1, item=response_text("ok"))) * response_sse((; type="response.completed", response=response_done([final_reasoning, response_text("ok")])))
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], payload)
    end
    try
        model = OpenAIResponses("http://$(HTTP.server_addr(server))/v1", "test", "synthetic")
        result = stream(model, [], Dict())
        @test result.done
        @test get(result.message["response_output"][1], "encrypted_content", nothing) == "synthetic-encrypted"
    finally
        close(server)
        wait(server)
    end
end

@testset "Responses reasoning reconciliation boundaries" begin
    model = OpenAIResponses("http://localhost/v1", "fixture", "synthetic")
    reasoning = response_reasoning()
    decoded = JuliaForever.reasoning(reasoning)
    @test decoded isa JuliaForever.ReasoningOutput
    @test decoded.id == "rs_1" && decoded.encrypted == "synthetic-encrypted"

    function encrypted(done, item)
        state = JuliaForever.ResponseStream(identity)
        done === nothing || (state.finished[0] = done)
        result = JuliaForever.finish(model, state, response_done([item]))
        get(result.message["response_output"][1], "encrypted_content", nothing)
    end
    missing = Dict("type" => "reasoning", "id" => "rs_1")
    @test encrypted(reasoning, copy(missing)) == "synthetic-encrypted"
    @test encrypted(nothing, copy(missing)) === nothing
    @test encrypted(merge(reasoning, Dict("id" => "other")), copy(missing)) === nothing
    @test encrypted(merge(reasoning, Dict("type" => "message")), copy(missing)) === nothing
    @test encrypted(reasoning, merge(missing, Dict("encrypted_content" => "kept"))) == "kept"
    @test encrypted(merge(reasoning, Dict("encrypted_content" => nothing)), copy(missing)) === nothing
    @test encrypted(reasoning, Dict("type" => "message", "id" => "rs_1")) === nothing
end

@testset "Responses message conversion" begin
    messages = Any[
        Dict("role" => "user", "content" => "hello"),
        Dict("role" => "assistant", "content" => "thinking", "tool_calls" => [Dict("id" => "c", "function" => Dict("name" => "read", "arguments" => "{}"))]),
        Dict("role" => "tool", "tool_call_id" => "c", "content" => "done"),
        Dict("role" => "assistant", "response_output" => [Dict("type" => "reasoning", "id" => "r")]),
    ]
    @test JuliaForever.input(messages) == Any[
        Dict("role" => "user", "content" => "hello"),
        Dict("role" => "assistant", "content" => "thinking"),
        Dict("type" => "function_call", "call_id" => "c", "name" => "read", "arguments" => "{}"),
        Dict("type" => "function_call_output", "call_id" => "c", "output" => "done"),
        Dict("type" => "reasoning", "id" => "r"),
    ]
    output = Any[
        Dict("type" => "message", "content" => Any[Dict("type" => "output_text", "text" => "yes"), Dict("type" => "refusal", "refusal" => "no"), Dict("type" => "other", "" => "ignored")]),
        Dict("type" => "function_call", "call_id" => "c", "name" => "read", "arguments" => "{}"),
        Dict("type" => "reasoning", "id" => "r"),
    ]
    result = JuliaForever.message(output)
    @test result["content"] == "yesno"
    @test result["tool_calls"] == [Dict("id" => "c", "type" => "function", "function" => Dict("name" => "read", "arguments" => "{}"))]
    @test result["response_output"] === output
end

@testset "Responses event conversion" begin
    @test JuliaForever.responseevent(Dict("type" => "response.output_text.delta", "delta" => "text")) isa JuliaForever.TextDelta
    @test JuliaForever.responseevent(Dict("type" => "response.refusal.delta", "delta" => "text")) isa JuliaForever.TextDelta
    @test JuliaForever.responseevent(Dict("type" => "response.reasoning_text.delta", "delta" => "text")) isa JuliaForever.ThinkingDelta
    @test JuliaForever.responseevent(Dict("type" => "response.output_item.added", "item" => Dict())) isa JuliaForever.OutputAdded
    @test JuliaForever.responseevent(Dict("type" => "response.function_call_arguments.delta", "delta" => "{}")) isa JuliaForever.ArgumentDelta
    @test JuliaForever.responseevent(Dict("type" => "response.output_item.done", "item" => Dict())) isa JuliaForever.OutputDone
    @test JuliaForever.responseevent(Dict("type" => "response.completed", "response" => Dict())) isa JuliaForever.ResponseEnded
    @test JuliaForever.responseevent(Dict("type" => "error", "message" => "bad")) isa JuliaForever.ResponseError
    @test isnothing(JuliaForever.responseevent(Dict("type" => "unknown")))
end

@testset "Responses event handling" begin
    events = Any[]
    state = JuliaForever.ResponseStream(event -> push!(events, event))
    receive(data) = JuliaForever.receive!(state, JSON3.write(data))
    receive(Dict("type" => "response.output_text.delta", "delta" => "hello"))
    receive(Dict("type" => "response.refusal.delta", "delta" => " there"))
    @test state.partial["content"] == "hello there"
    @test [event.type for event in events] == [:provider, :text, :provider, :text]
    receive(Dict("type" => "response.output_item.added", "item" => Dict("type" => "message")))
    @test isempty(state.active)
    receive(Dict("type" => "response.function_call_arguments.delta", "output_index" => 3))
    @test state.failure == "Responses stream contained an ambiguous function call delta"
    receive(Dict("type" => "response.output_item.done", "item" => Dict("type" => "message")))
    @test state.failure == "Responses stream omitted an output index"
end
