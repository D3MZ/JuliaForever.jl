@testset "Pi streamed Google Generative AI" begin
    source = ENV["PI_SOURCE"]
    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    chunks = google_chunks()
    mktemp() do path, io
        write(io, JSON3.write(chunks))
        flush(io)
        reference = JSON3.read(read(`node $(joinpath(@__DIR__, "provider_google_reference.mjs")) $source $path`, String))
        history = JSON3.read(read(`node $(joinpath(@__DIR__, "provider_google_reference.mjs")) $source $path history`, String))
        historical = Dict("id" => "call-1", "type" => "function", "function" => Dict("name" => "write", "arguments" => JSON3.write(Dict("path" => "a.txt", "content" => "ok"))))
        replaymodel = Google("https://generativelanguage.googleapis.com/v1beta", "gemini-3-fixture", "synthetic")
        saved = Dict("role" => "assistant", "content" => nothing, "tool_calls" => [historical], "google_origin" => JuliaForever.GoogleAPI.origin(replaymodel), "google_parts" => [Dict("functionCall" => Dict("id" => "call-1", "name" => "write", "args" => Dict("path" => "a.txt", "content" => "ok")), "thoughtSignature" => "c2lnbmVk")])
        tool = Dict("role" => "tool", "tool_call_id" => "call-1", "content" => "failed", "is_error" => true)
        replay = JSON3.read(JuliaForever.payload(replaymodel, [Dict("role" => "user", "content" => "hi"), saved, tool], Dict(), Dict()))
        @test replay.contents[2].parts[1] == history.payload.contents[2].parts[1]
        @test replay.contents[3].parts[1] == history.payload.contents[3].parts[1]
        requests = []
        server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
            push!(requests, (; target=request.target, body=JSON3.read(String(request.body))))
            HTTP.Response(200, ["Content-Type" => "text/event-stream"], join(googlesse.(chunks)))
        end
        try
            observed = []
            model = Google("http://$(HTTP.server_addr(server))/v1beta", "gemini-3-fixture", "synthetic")
            result = JuliaForever.stream(model, [Dict("role" => "user", "content" => "hi")], Dict(); on_event=event -> push!(observed, event))
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
            @test result.usage.reasoning == reference.result.usage.reasoning
            @test result.usage.total == reference.result.usage.totalTokens
            @test requests[1].body.contents[1].parts[1].text == reference.payload.contents[1].parts[1].text
            @test occursin(":streamGenerateContent?alt=sse", requests[1].target)
        finally
            close(server)
            wait(server)
        end
    end
end
