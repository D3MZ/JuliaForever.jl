using Test, JuliaForever, HTTP, JSON3

@testset "Gemini 2.5 budget thinking" begin
    requests = Any[]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        push!(requests, JSON3.read(String(request.body), Dict{String, Any}))
        event = Dict("candidates" => [Dict("content" => Dict("parts" => [Dict("thought" => true, "text" => "thought", "thoughtSignature" => "c2ln"), Dict("text" => "answer")]), "finishReason" => "STOP")])
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $(JSON3.write(event))\n\n")
    end
    try
        base = "http://$(HTTP.server_addr(server))"
        message = [Dict("role" => "user", "content" => "hello")]
        cases = ("gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-lite", "gemini-2.5-computer-use-preview-10-2025")
        for id in cases, level in ("off", "minimal", "low", "medium", "high")
            model = JuliaForever.applythinking(Google(base, id, "synthetic"), level)
            @test JuliaForever.stream(model, message, Dict()).done
            if haskey(ENV, "PI_SOURCE")
                source = ENV["PI_SOURCE"]
                @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
                reference = JSON3.read(read(`node $(joinpath(@__DIR__, "google_thinking_pi.mjs")) $source $id $level`, String), Dict{String, Any})
                @test requests[end]["generationConfig"]["thinkingConfig"] == reference["generationConfig"]["thinkingConfig"]
            end
        end
    finally
        close(server); wait(server)
    end
end
