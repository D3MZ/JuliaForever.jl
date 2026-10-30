using HTTP, JSON3

@testset "completion properties and JSON" begin
    for done in (true, false)
        used = Usage(1, 2, 3, 4, 5, 10, 0.25)
        result = Completion(Dict{String, Any}("role" => "assistant", "content" => "answer"), used, "stop", done, done ? nothing : "interrupted")
        data = JSON3.read(JSON3.write(result))
        @test Set(keys(data)) == Set([:message, :usage, :finish, :done, :error])
        @test data.done == done
        restored = JSON3.read(JSON3.write(result), Completion)
        @test restored.done == done && restored.error == result.error
        @test restored.message == result.message && restored.finish == result.finish
        @test restored.usage.total == 10 && restored.usage.cost == 0.25
    end
    @test Completion(Dict{String, Any}(), nothing, nothing, 1, nothing).done
    @test !Completion(Dict{String, Any}(), nothing, nothing, 0, nothing).done
end

@testset "chat finish reasons" begin
    reason = Ref{Union{Nothing, String}}("stop")
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        message = Dict("role" => "assistant", "content" => "answer")
        data = Dict("choices" => [Dict("message" => message, "finish_reason" => reason[])])
        HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(data))
    end
    try
        model = OpenAI("http://$(HTTP.server_addr(server))/v1", "fixture", "synthetic")
        for value in ("stop", "end", "length", "tool_calls", "function_call")
            reason[] = value
            result = JuliaForever.complete(model, [], Dict())
            @test result.done && result.finish == value && result.error === nothing
        end
        for value in (nothing, "content_filter")
            reason[] = value
            result = JuliaForever.complete(model, [], Dict())
            @test !result.done && result.finish == value
            @test result.error isa ProviderError
            @test result.error.kind == (isnothing(value) ? :unknown : :content_filter)
        end
    finally
        close(server)
        wait(server)
    end
end

@testset "provider usage decoding" begin
    @test JuliaForever.usage(nothing) === nothing
    plain = JuliaForever.usage(Dict{String, Any}("prompt_tokens" => 20, "completion_tokens" => 5, "prompt_tokens_details" => nothing, "completion_tokens_details" => nothing, "cost" => 0.003))
    @test (plain.input, plain.output, plain.cache_read, plain.cache_write, plain.reasoning, plain.total) == (20, 5, 0, 0, 0, 25)
    @test plain.cost ≈ 0.003
    byok = JuliaForever.usage(Dict{String, Any}("prompt_tokens" => 20, "completion_tokens" => 5, "prompt_tokens_details" => Dict("cached_tokens" => 4, "cache_write_tokens" => 2), "completion_tokens_details" => Dict("reasoning_tokens" => 3), "cost" => 0.003, "is_byok" => true, "cost_details" => Dict("upstream_inference_cost" => 0.002)))
    @test (byok.input, byok.output, byok.cache_read, byok.cache_write, byok.reasoning, byok.total) == (14, 5, 4, 2, 3, 25)
    @test byok.cost ≈ 0.005
    @test JuliaForever.usage(Dict("cost" => nothing, "is_byok" => true)).cost === nothing
    @test JuliaForever.usage(Dict("cost" => 0.003, "is_byok" => true, "cost_details" => nothing)).cost ≈ 0.003
    @test signbit(JuliaForever.usage(Dict("cost" => -0.0)).cost)
end

@testset "OpenAI-compatible provider" begin
    mktempdir() do dir
        requests = []
        server = HTTP.serve!("127.0.0.1", 0) do request
            push!(requests, (; target=request.target, authorization=HTTP.header(request, "Authorization"), body=JSON3.read(String(request.body))))
            message = if length(requests) == 1
                Dict("role" => "assistant", "content" => nothing, "tool_calls" => [Dict("id" => "call-1", "type" => "function", "function" => Dict("name" => "write", "arguments" => JSON3.write((; path="a.txt", content="hello"))))])
            else
                Dict("role" => "assistant", "content" => "done")
            end
            finish_reason = length(requests) == 1 ? "tool_calls" : "stop"
            HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write((; choices=[(; message, finish_reason)])))
        end
        try
            agent = Agent(OpenAI("http://127.0.0.1:$(HTTP.port(server))/v1", "test-model", "test-key"), [Write(dir), Read(dir), Edit(dir)])
            @test respond!(agent, "create a file"; parameters=Dict("stream" => true, "stream_options" => Dict("include_usage" => true))) == "done"
            @test length(requests) == 2
            @test requests[1].authorization == "Bearer test-key"
            @test requests[1].target == "/v1/chat/completions"
            @test requests[1].body.model == "test-model"
            @test requests[1].body.stream == false && !haskey(requests[1].body, :stream_options)
            @test requests[2].body.messages[end].role == "tool"
            @test requests[2].body.messages[end].tool_call_id == "call-1"
            @test read(joinpath(dir, "a.txt"), String) == "hello"
        finally
            close(server)
        end
    end
end

@testset "nonstreaming provider finish reasons" begin
    mktempdir() do dir
        requests = []
        reason = Ref{Union{Nothing, String}}("length")
        server = HTTP.serve!("127.0.0.1", 0) do request
            push!(requests, JSON3.read(String(request.body)))
            message = if length(requests) == 1
                Dict("role" => "assistant", "content" => nothing, "tool_calls" => [Dict("id" => "call-1", "type" => "function", "function" => Dict("name" => "write", "arguments" => JSON3.write((; path="partial.txt", content="bad"))))])
            else
                Dict("role" => "assistant", "content" => "recovered")
            end
            finish_reason = length(requests) == 1 ? reason[] : "stop"
            HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write((; choices=[(; message, finish_reason)], usage=(; prompt_tokens=5, completion_tokens=3))))
        end
        try
            provider = OpenAI("http://127.0.0.1:$(HTTP.port(server))/v1", "test-model", "test-key")
            agent = Agent(provider, [Write(dir)])
            @test respond!(agent, "write") == "recovered"
            @test !isfile(joinpath(dir, "partial.txt"))
            @test occursin("output token limit", requests[2].messages[end].content)

            empty!(requests)
            reason[] = "content_filter"
            filtered = Agent(provider, [Write(dir)])
            result = respond!(filtered, "write")
            @test result isa Completion && !result.done
            @test result.finish == "content_filter"
            @test result.usage.total == 8
            @test !isfile(joinpath(dir, "partial.txt"))
            @test [message["role"] for message in filtered.messages] == ["user"]
            @test length(requests) == 1

            empty!(requests)
            reason[] = nothing
            missing = Agent(provider, [Write(dir)])
            incomplete = respond!(missing, "write")
            @test incomplete isa Completion && !incomplete.done
            @test incomplete.finish === nothing
            @test [message["role"] for message in missing.messages] == ["user"]
            @test !isfile(joinpath(dir, "partial.txt"))
        finally
            close(server)
        end
    end
end
