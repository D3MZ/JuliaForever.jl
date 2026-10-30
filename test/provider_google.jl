using HTTP, JSON3

googlesse(data) = "data: $(JSON3.write(data))\n\n"

@testset "Google finish reasons" begin
    reason = Ref("STOP")
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        data = Dict("candidates" => [Dict("content" => Dict("parts" => [Dict("text" => "partial")]), "finishReason" => reason[])])
        HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(data))
    end
    try
        model = Google("http://$(HTTP.server_addr(server))/v1beta", "gemini-fixture", "synthetic")
        for (value, expected) in (("STOP", "stop"), ("MAX_TOKENS", "length"))
            reason[] = value
            result = JuliaForever.complete(model, [], Dict())
            @test result.done && result.finish == expected
        end
        reason[] = "SAFETY"
        result = JuliaForever.complete(model, [], Dict())
        @test !result.done && result.error isa ProviderError && result.error.provider == :google && result.error.kind == :safety
    finally
        close(server)
        wait(server)
    end
end

function google_chunks()
    [
        Dict("candidates" => [Dict("content" => Dict("role" => "model", "parts" => [Dict("thought" => true, "text" => "thinking")]))]),
        Dict("candidates" => [Dict("content" => Dict("role" => "model", "parts" => [Dict("text" => "hello")]))]),
        Dict("candidates" => [Dict("content" => Dict("role" => "model", "parts" => [Dict("functionCall" => Dict("id" => "call-1", "name" => "write", "args" => Dict("path" => "a.txt", "content" => "ok")), "thoughtSignature" => "c2lnbmVk")]), "finishReason" => "STOP")], "usageMetadata" => Dict("promptTokenCount" => 20, "cachedContentTokenCount" => 3, "candidatesTokenCount" => 4, "thoughtsTokenCount" => 2, "totalTokenCount" => 26))
    ]
end

@testset "Google Generative AI" begin
    requests = []
    replies = [
        Dict("candidates" => [Dict("content" => Dict("role" => "model", "parts" => [Dict("functionCall" => Dict("id" => "call-1", "name" => "write", "args" => Dict("path" => "a.txt", "content" => "ok")), "thoughtSignature" => "c2lnbmVk")]), "finishReason" => "STOP")], "usageMetadata" => Dict("promptTokenCount" => 20, "cachedContentTokenCount" => 3, "candidatesTokenCount" => 4, "thoughtsTokenCount" => 2, "totalTokenCount" => 26)),
        Dict("candidates" => [Dict("content" => Dict("role" => "model", "parts" => [Dict("text" => "done")]), "finishReason" => "STOP")])
    ]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        push!(requests, (; target=request.target, key=HTTP.header(request, "x-goog-api-key"), body=JSON3.read(String(request.body))))
        HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(popfirst!(replies)))
    end
    try
        mktempdir() do dir
            model = Google("http://$(HTTP.server_addr(server))/v1beta", "gemini-3-fixture", "test-secret")
            @test !occursin("test-secret", sprint(show, model))
            @test !occursin("test-secret", JSON3.write(model))
            agent = Agent(model, Dict{String, JuliaForever.Tool}("write" => Write(dir)), [Dict{String, Any}("role" => "system", "content" => "Be helpful")])
            @test respond!(agent, "write a file") == "done"
            @test read(joinpath(dir, "a.txt"), String) == "ok"
            @test requests[1].target == "/v1beta/models/gemini-3-fixture:generateContent"
            @test requests[1].key == "test-secret"
            @test requests[1].body.systemInstruction.parts[1].text == "Be helpful"
            @test requests[1].body.contents[1].parts[1].text == "write a file"
            @test requests[1].body.tools[1].functionDeclarations[1].name == "write"
            @test requests[2].body.contents[2].parts[1].thoughtSignature == "c2lnbmVk"
            @test requests[2].body.contents[2].parts[1].functionCall.id == "call-1"
            @test requests[2].body.contents[3].parts[1].functionResponse.id == "call-1"
            @test requests[2].body.contents[3].parts[1].functionResponse.name == "write"
            @test requests[2].body.contents[3].parts[1].functionResponse.response.output == "Successfully wrote to a.txt"
        end
        model = provider(Dict("JF_PROVIDER" => "google", "GEMINI_MODEL" => "gemini", "GEMINI_API_KEY" => "secret"))
        @test model isa Google
        @test model.base == "https://generativelanguage.googleapis.com/v1beta"
    finally
        close(server)
        wait(server)
    end
end

@testset "Google streaming" begin
    chunks = google_chunks()
    replies = [chunks, chunks[1:2], [Dict("candidates" => [Dict("finishReason" => "SAFETY")])]]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], join(googlesse.(popfirst!(replies))))
    end
    try
        model = Google("http://$(HTTP.server_addr(server))/v1beta", "gemini-3-fixture", "synthetic")
        seen = []
        result = JuliaForever.stream(model, [Dict("role" => "user", "content" => "hi")], Dict(); on_event=event -> push!(seen, event))
        @test result.done && result.finish == "tool_calls"
        @test result.message["content"] == "hello"
        @test result.message["google_parts"][3]["thoughtSignature"] == "c2lnbmVk"
        @test result.message["tool_calls"][1]["id"] == "call-1"
        @test JSON3.read(result.message["tool_calls"][1]["function"]["arguments"]).path == "a.txt"
        @test (result.usage.input, result.usage.output, result.usage.cache_read, result.usage.reasoning, result.usage.total) == (17, 6, 3, 2, 26)
        @test join(event.text for event in seen if event.type == :thinking) == "thinking"
        @test join(event.text for event in seen if event.type == :text) == "hello"
        @test !JuliaForever.stream(model, [], Dict()).done
        @test !JuliaForever.stream(model, [], Dict()).done
    finally
        close(server)
        wait(server)
    end
end

if haskey(ENV, "PI_SOURCE")
    include("provider_google_differential.jl")
end

@testset "Google tool identities and failure boundaries" begin
    call = Dict("id" => "one", "type" => "function", "function" => Dict("name" => "read", "arguments" => "{}"))
    assistant = Dict("role" => "assistant", "content" => nothing, "tool_calls" => [call])
    tool = Dict("role" => "tool", "tool_call_id" => "one", "content" => "failed", "is_error" => true)
    old = Google("http://fixture", "gemini-2.5-pro", "secret")
    fresh = Google("http://fixture", "gemini-3-flash", "secret")
    oldbody = JSON3.read(JuliaForever.payload(old, [assistant, tool], Dict(), Dict()))
    newbody = JSON3.read(JuliaForever.payload(fresh, [assistant, tool], Dict(), Dict()))
    @test !haskey(oldbody.contents[1].parts[1].functionCall, :id)
    @test !haskey(oldbody.contents[2].parts[1].functionResponse, :id)
    @test oldbody.contents[2].parts[1].functionResponse.response.error == "failed"
    @test newbody.contents[1].parts[1].functionCall.id == "one"
    @test newbody.contents[2].parts[1].functionResponse.id == "one"
    foreign = Dict("role" => "assistant", "content" => "safe", "google_origin" => "other", "google_parts" => [Dict("thought" => true, "text" => "private")])
    handoff = JSON3.read(JuliaForever.payload(fresh, [foreign], Dict(), Dict()))
    @test handoff.contents[1].parts[1].text == "safe"
    @test !haskey(handoff.contents[1].parts[1], :thought)
    input = Dict("role" => "assistant", "content" => "safe", "google_origin" => "other", "google_parts" => [])
    wire = JSON3.read(JuliaForever.payload(OpenAI("http://fixture", "fixture", "secret"), [input], Dict(), Dict()))
    @test !haskey(wire.messages[1], :google_parts)
    @test !haskey(wire.messages[1], :google_origin)

    chunks = google_chunks()
    bad = "data: {\n\n" * join(googlesse.(chunks))
    replies = [join(googlesse.(chunks[1:2])), bad, JSON3.write(Dict("error" => "test-secret")), JSON3.write(Dict("error" => "test-secret"))]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        body = popfirst!(replies)
        status = length(replies) <= 1 ? 401 : 200
        HTTP.Response(status, ["Content-Type" => status == 200 ? "text/event-stream" : "application/json"], body)
    end
    try
        mktempdir() do dir
            model = Google("http://$(HTTP.server_addr(server))/v1beta", "gemini-3-fixture", "test-secret")
            agent = Agent(model, [Write(dir)])
            result = respond!(agent, "write"; on_event=identity)
            @test result isa Completion && !result.done
            @test !isfile(joinpath(dir, "a.txt"))
            malformed = JuliaForever.stream(model, [], Dict())
            @test !malformed.done && malformed.error isa InvalidResponse
            failed = JuliaForever.complete(model, [], Dict())
            @test !failed.done && failed.error isa ProviderStatus && failed.error.status == 401
            @test !occursin("test-secret", sprint(show, failed))
            failedstream = JuliaForever.stream(model, [], Dict())
            @test !failedstream.done && failedstream.error isa ProviderStatus && failedstream.error.status == 401
            @test !occursin("test-secret", sprint(show, failedstream))
        end
    finally
        close(server)
        wait(server)
    end
end

@testset "Google streamed agent" begin
    requests = []
    chunks = google_chunks()
    second = [Dict("candidates" => [Dict("content" => Dict("role" => "model", "parts" => [Dict("text" => "done")]), "finishReason" => "STOP")])]
    replies = [chunks, second]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        push!(requests, JSON3.read(String(request.body)))
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], join(googlesse.(popfirst!(replies))))
    end
    try
        mktempdir() do dir
            model = Google("http://$(HTTP.server_addr(server))/v1beta", "gemini-3-fixture", "synthetic")
            agent = Agent(model, [Write(dir)])
            events = []
            @test respond!(agent, "write a file"; on_event=event -> push!(events, event)) == "done"
            @test read(joinpath(dir, "a.txt"), String) == "ok"
            @test requests[2].contents[2].parts[3].thoughtSignature == "c2lnbmVk"
            @test requests[2].contents[3].parts[1].functionResponse.id == "call-1"
            @test count(event -> event.type == :done, events) == 2
            @test any(event -> event.type == :finish && event.reason == "tool_calls", events)
        end
    finally
        close(server)
        wait(server)
    end
end
