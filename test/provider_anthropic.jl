using HTTP, JSON3

anthropicsse(event) = "event: " * event["type"] * "\ndata: " * JSON3.write(event) * "\n\n"

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

if haskey(ENV, "PI_SOURCE")
    include("provider_anthropic_differential.jl")
end

@testset "Anthropic tool streaming compatibility" begin
    reference = if haskey(ENV, "PI_SOURCE")
        source = ENV["PI_SOURCE"]
        @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
        JSON3.read(read(`node $(joinpath(@__DIR__, "provider_anthropic_tools_reference.mjs")) $source`, String))
    else
        JSON3.read("""[{"body":{"tools":[{"eager_input_streaming":true}]},"beta":null},{"body":{"tools":[{}]},"beta":"fine-grained-tool-streaming-2025-05-14"},{"body":{},"beta":null}]""")
    end
    requests = []
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        body = JSON3.read(String(request.body))
        push!(requests, (; body, beta=HTTP.header(request, "anthropic-beta", "")))
        body.stream && return HTTP.Response(200, ["Content-Type" => "text/event-stream"], join(anthropicsse.(anthropic_events())))
        HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(Dict("content" => [Dict("type" => "text", "text" => "ok")], "stop_reason" => "end_turn")))
    end
    try
        mktempdir() do dir
            tools = Dict("read" => Read(dir))
            input = [Dict("role" => "user", "content" => "hi")]
            base = "http://$(HTTP.server_addr(server))"
            models = [Anthropic(base, "claude-sonnet-4-5", "synthetic"; eager_tool_streaming=true), Anthropic(base, "claude-sonnet-4-5", "synthetic"; eager_tool_streaming=false), Anthropic(base, "claude-sonnet-4-5", "synthetic"; eager_tool_streaming=false)]
            for (model, exposed) in zip(models, (tools, tools, Dict()))
                @test JuliaForever.stream(model, input, exposed).done
            end
            for (request, expected) in zip(requests, reference)
                @test request.beta == something(expected.beta, "")
                @test haskey(request.body, :tools) == haskey(expected.body, :tools)
                if haskey(expected.body, :tools)
                    @test get(request.body.tools[1], :eager_input_streaming, nothing) == get(expected.body.tools[1], :eager_input_streaming, nothing)
                end
            end
            @test JuliaForever.complete(models[2], input, tools).done
            @test requests[end].beta == "fine-grained-tool-streaming-2025-05-14"
            @test !haskey(requests[end].body.tools[1], :eager_input_streaming)
            @test JuliaForever.stream(Anthropic(base, "custom-model", "synthetic"), input, tools).done
            @test isempty(requests[end].beta) && !haskey(requests[end].body.tools[1], :eager_input_streaming)
            builtin = Anthropic("https://api.anthropic.com", "claude-sonnet-4-5", "synthetic")
            @test JSON3.read(JuliaForever.payload(builtin, input, tools, Dict())).tools[1].eager_input_streaming
            for model in (Anthropic(base, "custom-model", "synthetic"), Anthropic("https://api.anthropic.com", "custom-model", "synthetic"), Anthropic(base, "claude-sonnet-4-5", "synthetic"))
                @test !haskey(JSON3.read(JuliaForever.payload(model, input, tools, Dict())).tools[1], :eager_input_streaming)
            end
        end
    finally
        close(server)
        wait(server)
    end
end
