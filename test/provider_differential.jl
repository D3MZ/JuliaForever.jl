@testset "Pi streamed completion" begin
    source = ENV["PI_SOURCE"]
    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    chunks = [
        Dict("choices" => [Dict("index" => 0, "delta" => Dict("reasoning_content" => "", "reasoning_text" => "think"), "finish_reason" => nothing)]),
        Dict("choices" => [Dict("index" => 0, "delta" => Dict("reasoning_content" => " next", "reasoning" => "duplicate", "content" => "hello"), "finish_reason" => nothing)]),
        Dict("choices" => [Dict("index" => 0, "delta" => Dict("content" => " world", "tool_calls" => [Dict("index" => 0, "id" => "call-1", "type" => "function", "function" => Dict("name" => "write", "arguments" => "{\"path\":\"a"))]), "finish_reason" => nothing)]),
        Dict("choices" => [Dict("index" => 0, "delta" => Dict("tool_calls" => [Dict("index" => 0, "function" => Dict("arguments" => ".txt\",\"content\":\"ok\"}"))]), "finish_reason" => "tool_calls")]),
        Dict("choices" => [], "usage" => Dict("prompt_tokens" => 20, "completion_tokens" => 5, "total_tokens" => 25, "prompt_tokens_details" => Dict("cached_tokens" => 4, "cache_write_tokens" => 2), "completion_tokens_details" => Dict("reasoning_tokens" => 3), "cost" => 0.003, "is_byok" => true, "cost_details" => Dict("upstream_inference_cost" => 0.002))),
    ]
    mktemp() do path, io
        write(io, JSON3.write(chunks))
        flush(io)
        reference = JSON3.read(read(`node $(joinpath(@__DIR__, "provider_reference.mjs")) $source $path`, String))
        server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
            HTTP.Response(200, ["Content-Type" => "text/event-stream"], join(sse.(chunks)) * "data: [DONE]\n\n")
        end
        try
            events = []
            model = OpenAI("http://$(HTTP.server_addr(server))/v1", "vendor/model", "synthetic")
            result = JuliaForever.stream(model, [Dict("role" => "user", "content" => "hi")], Dict(); on_event=event -> push!(events, event))
            @test result.done
            @test result.message["content"] == only([block.text for block in reference.content if block.type == "text"])
            @test join(event.text for event in events if event.type == :thinking) == only([block.thinking for block in reference.content if block.type == "thinking"])
            reference_thinking = only([block for block in reference.content if block.type == "thinking"])
            @test reference_thinking.thinkingSignature == "reasoning_text"
            @test get(result.message, reference_thinking.thinkingSignature, nothing) == reference_thinking.thinking
            @test !haskey(result.message, "reasoning_content")
            call = result.message["tool_calls"][1]
            reference_call = only([block for block in reference.content if block.type == "toolCall"])
            @test call["id"] == reference_call.id
            @test call["function"]["name"] == reference_call.name
            @test JSON3.read(call["function"]["arguments"]) == reference_call.arguments
            @test result.finish == "tool_calls" && reference.stopReason == "toolUse"
            @test result.usage.input == reference.usage.input
            @test result.usage.output == reference.usage.output
            @test result.usage.cache_read == reference.usage.cacheRead
            @test result.usage.cache_write == reference.usage.cacheWrite
            @test result.usage.reasoning == reference.usage.reasoning
            @test result.usage.total == reference.usage.totalTokens
            @test result.usage.cost ≈ reference.usage.cost.total
        finally
            close(server)
            wait(server)
        end
    end
end
