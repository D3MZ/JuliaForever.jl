@testset "Pi streamed Anthropic messages" begin
    source = ENV["PI_SOURCE"]
    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    events = anthropic_events()
    mktemp() do path, io
        write(io, JSON3.write(events))
        flush(io)
        reference = JSON3.read(read(`node $(joinpath(@__DIR__, "provider_anthropic_reference.mjs")) $source $path`, String))
        requests = []
        server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
            push!(requests, JSON3.read(String(request.body)))
            HTTP.Response(200, ["Content-Type" => "text/event-stream"], join(anthropicsse.(events)))
        end
        try
            observed = []
            model = Anthropic("http://$(HTTP.server_addr(server))", "claude-fixture", "synthetic")
            result = JuliaForever.stream(model, [Dict("role" => "user", "content" => "hi")], Dict(); parameters=Dict("max_tokens" => 90), on_event=event -> push!(observed, event))
            @test result.done
            @test result.message["content"] == only([part.text for part in reference.result.content if part.type == "text"])
            @test join(event.text for event in observed if event.type == :thinking) == only([part.thinking for part in reference.result.content if part.type == "thinking"])
            call = only(result.message["tool_calls"])
            reference_call = only([part for part in reference.result.content if part.type == "toolCall"])
            @test call["id"] == reference_call.id
            @test call["function"]["name"] == reference_call.name
            @test JSON3.read(call["function"]["arguments"]) == reference_call.arguments
            @test result.finish == "tool_calls" && reference.result.stopReason == "toolUse"
            @test result.usage.input == reference.result.usage.input
            @test result.usage.output == reference.result.usage.output
            @test result.usage.cache_read == reference.result.usage.cacheRead
            @test result.usage.cache_write == reference.result.usage.cacheWrite
            @test result.usage.total == reference.result.usage.totalTokens
            @test requests[1].model == reference.payload.model
            @test requests[1].max_tokens == reference.payload.max_tokens
            @test requests[1].messages[1].content == reference.payload.messages[1].content
        finally
            close(server)
            wait(server)
        end
    end
end
