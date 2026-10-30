using HTTP, JSON3, Base64, SHA

@testset "provider configuration" begin
    openai = JuliaForever.provider(Dict("OPENAI_MODEL" => "model-a", "OPENAI_API_KEY" => "synthetic-a", "PI_CODING_AGENT_DIR" => mktempdir()))
    @test openai.base == "https://api.openai.com/v1"
    @test openai.model == "model-a"
    @test openai.key == "synthetic-a"
    @test !occursin("synthetic-a", sprint(show, openai))
    @test !occursin("synthetic-a", sprint(show, MIME("text/plain"), openai))
    router = JuliaForever.provider(Dict("JF_PROVIDER" => "openrouter", "OPENROUTER_MODEL" => "vendor/model-b", "OPENROUTER_API_KEY" => "synthetic-b", "OPENROUTER_BASE_URL" => "http://localhost/router/", "PI_CODING_AGENT_DIR" => mktempdir(), "JF_OPENROUTER_DIR" => joinpath(mktempdir(), "router")))
    @test router.base == "http://localhost/router/"
    @test router.model == "vendor/model-b"
    @test router.key == "synthetic-b"
    @test JuliaForever.provider(Dict("JF_PROVIDER" => "unknown")) === nothing
end

sse(data) = "data: $(JSON3.write(data))\n\n"

@testset "streamed completions" begin
    received = Channel{Any}(1)
    observed = Channel{Nothing}(1)
    server = HTTP.listen!("127.0.0.1", 0; listenany=true) do io
        request = HTTP.startread(io)
        body = JSON3.read(String(read(io)))
        put!(received, (; target=request.target, authorization=HTTP.header(request, "Authorization"), body))
        HTTP.setheader(io, "Content-Type" => "text/event-stream")
        HTTP.startwrite(io)
        write(io, ": keepalive\r\n\r\n", sse((; choices=[(; index=0, delta=(; role="assistant", content="hello"), finish_reason=nothing)])))
        flush(io)
        take!(observed)
        write(io, sse((; choices=[(; index=0, delta=(; content=" world", tool_calls=[Dict("index" => 0, "id" => "call-1", "type" => "function", "function" => Dict("name" => "write", "arguments" => "{\"path\":\"a"))]), finish_reason=nothing)])))
        write(io, sse((; choices=[(; index=0, delta=(; tool_calls=[Dict("index" => 0, "function" => Dict("arguments" => ".txt\",\"content\":\"ok\"}"))]), finish_reason="tool_calls")])) )
        write(io, sse((; choices=[], usage=(; prompt_tokens=20, completion_tokens=5, total_tokens=25, prompt_tokens_details=(; cached_tokens=4, cache_write_tokens=2), completion_tokens_details=(; reasoning_tokens=3), cost=0.003, is_byok=true, cost_details=(; upstream_inference_cost=0.002)))))
        write(io, "data: [DONE]\n\n")
    end
    try
        base = "http://$(HTTP.server_addr(server))/v1/"
        model = OpenAI(base, "vendor/model", "synthetic-key")
        events = []
        result = JuliaForever.stream(model, [Dict("role" => "user", "content" => "hi")], Dict(); parameters=Dict("temperature" => 0.2, "model" => "ignored", "tools" => ["ignored"], "stream" => false, "stream_options" => Dict("include_usage" => false)), on_event=event -> begin
            push!(events, event)
            event.type == :text && event.text == "hello" && put!(observed, nothing)
        end)
        request = take!(received)
        @test request.target == "/v1/chat/completions"
        @test request.authorization == "Bearer synthetic-key"
        @test request.body.model == "vendor/model"
        @test request.body.stream == true
        @test request.body.stream_options.include_usage == true
        @test request.body.temperature == 0.2
        @test !haskey(request.body, :tools)
        @test result.status isa JuliaForever.Finished
        @test result.done
        @test result.error === nothing
        @test result.finish == "tool_calls"
        @test result.message["role"] == "assistant"
        @test result.message["content"] == "hello world"
        @test result.message["tool_calls"][1]["id"] == "call-1"
        @test result.message["tool_calls"][1]["function"]["name"] == "write"
        @test JSON3.read(result.message["tool_calls"][1]["function"]["arguments"]).path == "a.txt"
        @test result.usage.input == 14
        @test result.usage.output == 5
        @test result.usage.cache_read == 4
        @test result.usage.cache_write == 2
        @test result.usage.reasoning == 3
        @test result.usage.total == 25
        @test result.usage.cost ≈ 0.005
        @test [event.text for event in events if event.type == :text] == ["hello", " world"]
        @test any(event -> event.type == :tool_call, events)
        @test any(event -> event.type == :provider, events)
    finally
        close(server)
        wait(server)
    end
end

@testset "stream interruption and provider error" begin
    replies = [sse((; choices=[(; index=0, delta=(; content="partial"), finish_reason=nothing)])), sse((; error=(; message="capacity", code=503))) * "data: [DONE]\n\n"]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], popfirst!(replies))
    end
    try
        model = OpenAI("http://$(HTTP.server_addr(server))/v1", "test", "synthetic")
        partial = JuliaForever.stream(model, [], Dict())
        @test !partial.done
        @test partial.message["content"] == "partial"
        @test partial.usage === nothing
        failed = JuliaForever.stream(model, [], Dict())
        @test !failed.done
        @test failed.error isa ProviderError && failed.error.provider == :openai_compatible && failed.error.status == 503
        @test failed.usage === nothing
    finally
        close(server)
        wait(server)
    end
end

@testset "OpenRouter headless login" begin
    first = JuliaForever.authorize()
    second = JuliaForever.authorize()
    @test first.verifier != second.verifier
    @test length(first.verifier) == 43
    @test occursin(r"^[A-Za-z0-9_-]{43}$", first.verifier)
    challenge = rstrip(replace(Base64.base64encode(SHA.sha256(first.verifier)), "+" => "-", "/" => "_"), '=')
    @test occursin("code_challenge=$challenge", first.url)
    @test occursin("code_challenge_method=S256", first.url)
    @test !occursin("callback_url", first.url)
    @test !occursin(first.verifier, sprint(show, first))
    seen = Channel{Any}(2)
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        put!(seen, (; target=request.target, body=JSON3.read(String(request.body))))
        HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write((; key="synthetic-openrouter-key")))
    end
    try
        key = JuliaForever.exchange(first, "synthetic-code"; base="http://$(HTTP.server_addr(server))/api/v1")
        request = take!(seen)
        @test request.target == "/api/v1/auth/keys"
        @test request.body.code == "synthetic-code"
        @test request.body.code_verifier == first.verifier
        @test request.body.code_challenge_method == "S256"
        @test key == "synthetic-openrouter-key"
    finally
        close(server)
        wait(server)
    end
end

@testset "streamed agent tool loop" begin
    requests = Any[]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        body = JSON3.read(String(request.body))
        push!(requests, body)
        chunk = if length(requests) == 1
            Dict("choices" => [Dict("index" => 0, "delta" => Dict("tool_calls" => [Dict("index" => 0, "id" => "call-stream", "function" => Dict("name" => "write", "arguments" => "{\"path\":\"file.txt\",\"content\":\"streamed\"}"))]), "finish_reason" => "tool_calls")])
        else
            (; choices=[(; index=0, delta=(; content="done"), finish_reason="stop")])
        end
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], sse(chunk) * "data: [DONE]\n\n")
    end
    try
        mktempdir() do dir
            agent = Agent(OpenAI("http://$(HTTP.server_addr(server))/v1", "test", "synthetic"), [Write(dir)])
            events = []
            @test respond!(agent, "create file"; on_event=event -> push!(events, event)) == "done"
            @test read(joinpath(dir, "file.txt"), String) == "streamed"
            @test length(requests) == 2
            @test requests[1].tools[1].function.name == "write"
            @test requests[2].messages[end].role == "tool"
            @test requests[2].messages[end].tool_call_id == "call-stream"
            @test count(event -> event.type == :done, events) == 2
        end
    finally
        close(server)
        wait(server)
    end
end

@testset "provider failures" begin
    replies = [HTTP.Response(200, ["Content-Type" => "text/event-stream"], sse((; choices=[(; delta=(; content="blocked"), finish_reason="content_filter")])) * "data: [DONE]\n\n"), HTTP.Response(401, ["Content-Type" => "application/json"], "{\"error\":\"unauthorized\"}"), HTTP.Response(200, ["Content-Type" => "application/json"], "{}")]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        popfirst!(replies)
    end
    try
        base = "http://$(HTTP.server_addr(server))/v1"
        model = OpenAI(base, "test", "synthetic")
        failed = JuliaForever.stream(model, [], Dict())
        @test !failed.done
        @test failed.error isa ProviderError && failed.error.kind == :content_filter
        @test JuliaForever.stream(model, [], Dict()).error == ProviderStatus(401)
        @test JuliaForever.exchange(JuliaForever.authorize(), "synthetic-code"; base) === nothing
    finally
        close(server)
        wait(server)
    end
end

if haskey(ENV, "PI_SOURCE")
    include("provider_differential.jl")
end

@testset "headless login CLI" begin
    requests = Any[]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        body = JSON3.read(String(request.body))
        push!(requests, (; target=request.target, authorization=HTTP.header(request, "Authorization", nothing), body))
        if request.target == "/api/v1/auth/keys"
            HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write((; key="synthetic-secret")))
        else
            chunk = (; choices=[(; delta=(; content="CLI done"), finish_reason="stop")])
            HTTP.Response(200, ["Content-Type" => "text/event-stream"], sse(chunk) * "data: [DONE]\n\n")
        end
    end
    try
        base = "http://$(HTTP.server_addr(server))/api/v1"
        project = dirname(@__DIR__)
        cmd = addenv(`$(Base.julia_cmd()) --project=$project -m JuliaForever --no-session --login-openrouter hello`, "OPENROUTER_BASE_URL" => base, "OPENROUTER_MODEL" => "fixture/model", "JF_OPENROUTER_DIR" => joinpath(mktempdir(), "router"))
        output = mktemp() do path, io
            write(io, "synthetic-code\n")
            flush(io)
            read(pipeline(cmd; stdin=path), String)
        end
        @test occursin("https://openrouter.ai/auth?", output)
        @test occursin("CLI done", output)
        @test !occursin("synthetic-secret", output)
        @test length(requests) == 2
        @test requests[1].body.code == "synthetic-code"
        @test !occursin(requests[1].body.code_verifier, output)
        @test requests[2].authorization == "Bearer synthetic-secret"
        @test requests[2].body.model == "fixture/model"
    finally
        close(server)
        wait(server)
    end
end

@testset "nonstreaming agent tool loop" begin
    requests = Any[]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        body = JSON3.read(String(request.body))
        push!(requests, (; target=request.target, authorization=HTTP.header(request, "Authorization"), body))
        message = if length(requests) == 1
            Dict("role" => "assistant", "content" => nothing, "tool_calls" => [Dict("id" => "call-1", "type" => "function", "function" => Dict("name" => "write", "arguments" => "{\"path\":\"a.txt\",\"content\":\"hello\"}"))])
        else
            Dict("role" => "assistant", "content" => "done")
        end
        finish = length(requests) == 1 ? "tool_calls" : "stop"
        HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(Dict("choices" => [Dict("message" => message, "finish_reason" => finish)])))
    end
    try
        mktempdir() do dir
            agent = Agent(OpenAI("http://$(HTTP.server_addr(server))/v1", "test-model", "synthetic-key"), [Write(dir), Read(dir), Edit(dir)])
            @test respond!(agent, "create a file") == "done"
            @test length(requests) == 2
            @test requests[1].authorization == "Bearer synthetic-key"
            @test requests[1].target == "/v1/chat/completions"
            @test requests[1].body.model == "test-model"
            @test requests[2].body.messages[end].role == "tool"
            @test requests[2].body.messages[end].tool_call_id == "call-1"
            @test read(joinpath(dir, "a.txt"), String) == "hello"
        end
    finally
        close(server)
        wait(server)
    end
end
