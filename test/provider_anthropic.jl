using HTTP, JSON3

anthropicsse(event) = "event: " * event["type"] * "\ndata: " * JSON3.write(event) * "\n\n"

@testset "Anthropic messages" begin
    requests = []
    responses = [
        Dict("id" => "msg-1", "type" => "message", "role" => "assistant", "content" => [Dict("type" => "thinking", "thinking" => "consider", "signature" => "signed"), Dict("type" => "text", "text" => "hello"), Dict("type" => "tool_use", "id" => "call-1", "name" => "write", "input" => Dict("path" => "a.txt", "content" => "written"))], "stop_reason" => "tool_use", "usage" => Dict("input_tokens" => 11, "output_tokens" => 4, "cache_read_input_tokens" => 2, "cache_creation_input_tokens" => 3)),
        Dict("id" => "msg-2", "type" => "message", "role" => "assistant", "content" => [Dict("type" => "text", "text" => "done")], "stop_reason" => "end_turn", "usage" => Dict("input_tokens" => 20, "output_tokens" => 2))
    ]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        push!(requests, (; target=request.target, key=HTTP.header(request, "x-api-key"), version=HTTP.header(request, "anthropic-version"), body=JSON3.read(String(request.body))))
        HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(popfirst!(responses)))
    end
    try
        mktempdir() do dir
            model = Anthropic("http://$(HTTP.server_addr(server))", "claude-fixture", "test-secret")
            @test !occursin("test-secret", sprint(show, model))
            @test !occursin("test-secret", JSON3.write(model))
            agent = Agent(model, Dict{String, JuliaForever.Tool}("write" => Write(dir)), [Dict{String, Any}("role" => "system", "content" => "Be helpful")])
            @test respond!(agent, "write a file"; parameters=Dict("max_tokens" => 90)) == "done"
            @test read(joinpath(dir, "a.txt"), String) == "written"
            @test length(requests) == 2
            @test requests[1].target == "/v1/messages"
            @test requests[1].key == "test-secret"
            @test requests[1].version == "2023-06-01"
            @test requests[1].body.model == "claude-fixture"
            @test requests[1].body.max_tokens == 90
            @test requests[1].body.system == "Be helpful"
            @test requests[1].body.messages[1].role == "user"
            @test requests[1].body.tools[1].name == "write"
            @test requests[1].body.tools[1].input_schema.type == "object"
            @test requests[2].body.messages[2].role == "assistant"
            @test requests[2].body.messages[2].content[1].signature == "signed"
            @test requests[2].body.messages[2].content[3].id == "call-1"
            @test requests[2].body.messages[3].role == "user"
            @test requests[2].body.messages[3].content[1].type == "tool_result"
            @test requests[2].body.messages[3].content[1].tool_use_id == "call-1"
            previous = agent.messages[3]
            other = Anthropic("http://different-origin", "different-model", "synthetic")
            handoff = JSON3.read(JuliaForever.payload(other, [previous], Dict(), Dict()))
            @test all(block.type != "thinking" for block in handoff.messages[1].content)
            @test handoff.messages[1].content[end].id == "call-1"
        end
        model = provider(Dict("JF_PROVIDER" => "anthropic", "ANTHROPIC_MODEL" => "claude", "ANTHROPIC_API_KEY" => "secret"))
        @test model isa Anthropic
        @test model.base == "https://api.anthropic.com"
    finally
        close(server)
        wait(server)
    end
end

function anthropic_events()
    [
        Dict("type" => "message_start", "message" => Dict("id" => "msg-1", "role" => "assistant", "model" => "claude-fixture", "content" => [], "stop_reason" => nothing, "usage" => Dict("input_tokens" => 11, "output_tokens" => 0, "cache_read_input_tokens" => 2, "cache_creation_input_tokens" => 3))),
        Dict("type" => "content_block_start", "index" => 0, "content_block" => Dict("type" => "thinking", "thinking" => "", "signature" => "")),
        Dict("type" => "content_block_delta", "index" => 0, "delta" => Dict("type" => "thinking_delta", "thinking" => "think")),
        Dict("type" => "content_block_delta", "index" => 0, "delta" => Dict("type" => "signature_delta", "signature" => "signed")),
        Dict("type" => "content_block_stop", "index" => 0),
        Dict("type" => "content_block_start", "index" => 1, "content_block" => Dict("type" => "text", "text" => "")),
        Dict("type" => "content_block_delta", "index" => 1, "delta" => Dict("type" => "text_delta", "text" => "hello")),
        Dict("type" => "content_block_stop", "index" => 1),
        Dict("type" => "content_block_start", "index" => 2, "content_block" => Dict("type" => "tool_use", "id" => "call-1", "name" => "write", "input" => Dict())),
        Dict("type" => "content_block_delta", "index" => 2, "delta" => Dict("type" => "input_json_delta", "partial_json" => "{\"path\":\"a")),
        Dict("type" => "content_block_delta", "index" => 2, "delta" => Dict("type" => "input_json_delta", "partial_json" => ".txt\",\"content\":\"ok\"}")),
        Dict("type" => "content_block_stop", "index" => 2),
        Dict("type" => "message_delta", "delta" => Dict("stop_reason" => "tool_use"), "usage" => Dict("output_tokens" => 4)),
        Dict("type" => "message_stop")
    ]
end

@testset "Anthropic streaming" begin
    events = anthropic_events()
    replies = [events, events[1:end-1], [events[1], Dict("type" => "error", "error" => Dict("message" => "overloaded"))], [events[1:end-3]..., Dict("type" => "message_delta", "delta" => Dict("stop_reason" => "refusal"), "usage" => Dict("output_tokens" => 4)), events[end]]]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], join(anthropicsse.(popfirst!(replies))))
    end
    try
        model = Anthropic("http://$(HTTP.server_addr(server))", "claude-fixture", "synthetic")
        seen = []
        result = JuliaForever.stream(model, [Dict("role" => "user", "content" => "hi")], Dict(); on_event=event -> push!(seen, event))
        @test result.done
        @test result.finish == "tool_calls"
        @test result.message["content"] == "hello"
        @test result.message["anthropic_content"][1]["signature"] == "signed"
        @test result.message["tool_calls"][1]["id"] == "call-1"
        @test JSON3.read(result.message["tool_calls"][1]["function"]["arguments"]).path == "a.txt"
        @test (result.usage.input, result.usage.output, result.usage.cache_read, result.usage.cache_write, result.usage.total) == (11, 4, 2, 3, 20)
        @test join(event.text for event in seen if event.type == :thinking) == "think"
        @test join(event.text for event in seen if event.type == :text) == "hello"
        @test join(event.arguments for event in seen if event.type == :tool_call) == "{\"path\":\"a.txt\",\"content\":\"ok\"}"
        @test !JuliaForever.stream(model, [], Dict()).done
        failed = JuliaForever.stream(model, [], Dict())
        @test !failed.done && occursin("overloaded", failed.error)
        refused = JuliaForever.stream(model, [], Dict())
        @test !refused.done
    finally
        close(server)
        wait(server)
    end
end

if haskey(ENV, "PI_SOURCE")
    include("provider_anthropic_differential.jl")
end

@testset "Anthropic tool failure and interrupted stream" begin
    requests = []
    replies = [
        HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(Dict("content" => [Dict("type" => "tool_use", "id" => "read-1", "name" => "read", "input" => Dict("path" => "absent"))], "stop_reason" => "tool_use", "usage" => Dict("input_tokens" => 2, "output_tokens" => 3)))),
        HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(Dict("content" => [Dict("type" => "text", "text" => "missing")], "stop_reason" => "end_turn"))),
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], join(anthropicsse.(anthropic_events()[1:end-1]))),
        HTTP.Response(401, ["Content-Type" => "application/json"], "{\"error\":\"synthetic-secret\"}"),
        HTTP.Response(401, ["Content-Type" => "application/json"], "{\"error\":\"synthetic-secret\"}")
    ]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        push!(requests, JSON3.read(String(request.body)))
        popfirst!(replies)
    end
    try
        mktempdir() do dir
            model = Anthropic("http://$(HTTP.server_addr(server))", "claude-fixture", "synthetic-secret")
            agent = Agent(model, [Read(dir), Write(dir)])
            @test respond!(agent, "read absent") == "missing"
            @test requests[2].messages[end].content[1].is_error == true
            interrupted = respond!(agent, "write a.txt"; on_event=identity)
            @test interrupted isa Completion && !interrupted.done
            @test !isfile(joinpath(dir, "a.txt"))
            failed = JuliaForever.complete(model, [Dict("role" => "user", "content" => "hi")], Dict())
            @test !failed.done && occursin("401", failed.error)
            @test !occursin("synthetic-secret", sprint(show, failed))
            failedstream = JuliaForever.stream(model, [Dict("role" => "user", "content" => "hi")], Dict())
            @test !failedstream.done && occursin("401", failedstream.error)
            @test !occursin("synthetic-secret", sprint(show, failedstream))
        end
        tool = Dict("role" => "tool", "content" => "failed", "tool_call_id" => "id", "is_error" => true)
        assistant = Dict("role" => "assistant", "content" => "hello", "anthropic_content" => [], "anthropic_origin" => "origin", "response_output" => [])
        openai = OpenAI("http://fixture", "fixture", "secret")
        wire = JSON3.read(JuliaForever.payload(openai, [assistant, tool], Dict(), Dict()))
        named = JSON3.read(JuliaForever.payload(openai, [(; role="user", content="hi")], Dict(), Dict()))
        @test named.messages[1].content == "hi"
        @test !haskey(wire.messages[1], :anthropic_content)
        @test !haskey(wire.messages[1], :anthropic_origin)
        @test !haskey(wire.messages[1], :response_output)
        @test !haskey(wire.messages[2], :is_error)
    finally
        close(server)
        wait(server)
    end
end

@testset "Anthropic invalid streams" begin
    events = anthropic_events()
    malformed = join(anthropicsse.(events[1:9])) * "event: content_block_delta\ndata: {\n\n" * join(anthropicsse.(events[10:end]))
    invalidargs = deepcopy(events)
    invalidargs[10]["delta"]["partial_json"] = "{"
    invalidargs[11]["delta"]["partial_json"] = ""
    duplicated = deepcopy(events)
    insert!(duplicated, 13, Dict("type" => "content_block_start", "index" => 3, "content_block" => Dict("type" => "tool_use", "id" => "call-1", "name" => "write", "input" => Dict())))
    insert!(duplicated, 14, Dict("type" => "content_block_stop", "index" => 3))
    replies = [malformed, join(anthropicsse.(invalidargs)), join(anthropicsse.(duplicated))]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], popfirst!(replies))
    end
    try
        model = Anthropic("http://$(HTTP.server_addr(server))", "claude-fixture", "synthetic")
        malformed_result = JuliaForever.stream(model, [], Dict())
        @test !malformed_result.done && malformed_result.error isa InvalidResponse
        invalid_result = JuliaForever.stream(model, [], Dict())
        @test !invalid_result.done && invalid_result.error isa InvalidResponse
        @test !JuliaForever.stream(model, [], Dict()).done
    finally
        close(server)
        wait(server)
    end
end

@testset "Anthropic streamed agent" begin
    requests = []
    first = anthropic_events()
    second = [first[1], Dict("type" => "content_block_start", "index" => 0, "content_block" => Dict("type" => "text", "text" => "")), Dict("type" => "content_block_delta", "index" => 0, "delta" => Dict("type" => "text_delta", "text" => "done")), Dict("type" => "content_block_stop", "index" => 0), Dict("type" => "message_delta", "delta" => Dict("stop_reason" => "end_turn"), "usage" => Dict("output_tokens" => 1)), Dict("type" => "message_stop")]
    replies = [first, second]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        push!(requests, JSON3.read(String(request.body)))
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], join(anthropicsse.(popfirst!(replies))))
    end
    try
        mktempdir() do dir
            model = Anthropic("http://$(HTTP.server_addr(server))", "claude-fixture", "synthetic")
            agent = Agent(model, [Write(dir)])
            events = []
            @test respond!(agent, "write a file"; on_event=event -> push!(events, event)) == "done"
            @test read(joinpath(dir, "a.txt"), String) == "ok"
            @test requests[2].messages[2].content[1].signature == "signed"
            @test requests[2].messages[3].content[1].tool_use_id == "call-1"
            @test count(event -> event.type == :done, events) == 2
        end
    finally
        close(server)
        wait(server)
    end
end
