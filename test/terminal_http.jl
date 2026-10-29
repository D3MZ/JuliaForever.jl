using Test, JuliaForever, HTTP, JSON3

function terminal_http(base, prompt; provider="openai")
    project = dirname(@__DIR__)
    cmd = addenv(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project -m JuliaForever --no-session $prompt`, "JF_PROVIDER" => provider, "OPENAI_BASE_URL" => base, "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "synthetic-secret")
    mktempdir() do dir
        output, diagnostics = joinpath.((dir,), ("output", "diagnostics"))
        process = run(pipeline(ignorestatus(cmd); stdout=output, stderr=diagnostics))
        (; status=process.exitcode, output=read(output, String), diagnostics=read(diagnostics, String))
    end
end

@testset "terminal loopback HTTP" begin
    requests = []
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        body = JSON3.read(String(request.body))
        push!(requests, (; target=request.target, authorization=HTTP.header(request, "Authorization"), stream=body.stream))
        input = request.target == "/v1/responses" ? body.input[end].content : body.messages[end].content
        if input == "http"
            return HTTP.Response(401, ["Content-Type" => "application/json"], "{\"error\":\"synthetic-secret raw-event\"}")
        elseif input == "json"
            return HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: {synthetic-secret raw-event}\n\n")
        elseif input == "shape"
            data = JSON3.write((; choices=[(; delta=(;), finish_reason=(; token="synthetic-secret", raw="raw-event"))]))
            return HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $data\n\n")
        elseif input == "partial"
            data = JSON3.write((; choices=[(; delta=(; content="partial"), finish_reason="stop")]))
            return HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $data\n\n")
        elseif request.target == "/v1/responses"
            delta = JSON3.write((; type="response.output_text.delta", delta="Responses"))
            output = [(; type="message", content=[(; type="output_text", text="Responses")])]
            done = JSON3.write((; type="response.completed", response=(; status="completed", output)))
            return HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $delta\n\ndata: $done\n\n")
        end
        data = JSON3.write((; choices=[(; delta=(; content="Hello"), finish_reason="stop")]))
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $data\n\ndata: [DONE]\n\n")
    end
    try
        base = "http://$(HTTP.server_addr(server))/v1"
        @test terminal_http(base, "ok") == (; status=0, output="Hello\n", diagnostics="")
        @test terminal_http(base, "ok"; provider="openai-responses") == (; status=0, output="Responses\n", diagnostics="")
        @test terminal_http(base, "partial") == (; status=1, output="partial\n", diagnostics="Response incomplete: the provider stream did not finish\n")
        @test terminal_http(base, "http") == (; status=1, output="", diagnostics="Request failed (HTTP 401).\n")
        @test terminal_http(base, "json") == (; status=1, output="", diagnostics="Request failed (invalid provider response).\n")
        invalid = terminal_http(base, "shape")
        @test invalid.status == 1
        @test !occursin("synthetic-secret", invalid.diagnostics)
        @test !occursin("raw-event", invalid.diagnostics)
        @test all(request -> request.authorization == "Bearer synthetic-secret" && request.stream, requests)
    finally
        close(server)
        wait(server)
    end
end
