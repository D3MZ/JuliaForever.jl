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
        cases = (("gemini-2.5-pro", (128, 2048, 8192, 32768)), ("gemini-2.5-flash", (128, 2048, 8192, 24576)), ("gemini-2.5-flash-lite", (512, 2048, 8192, 24576)), ("gemini-2.5-computer-use-preview-10-2025", (-1, -1, -1, -1)))
        config = Dict{String, Any}("temperature" => 0.25, "thinkingConfig" => Dict("thinkingLevel" => "LOW"))
        parameters = Dict("generationConfig" => deepcopy(config))
        provider = JuliaForever.applythinking(Google(base, "gemini-2.5-pro", "synthetic"), "high")
        @test JuliaForever.stream(provider, message, Dict(); parameters).done
        @test parameters["generationConfig"] == config
        @test requests[end]["generationConfig"] == Dict("temperature" => 0.25, "thinkingConfig" => Dict("includeThoughts" => true, "thinkingBudget" => 32768))
        for (id, budgets) in cases, (level, budget) in zip(("off", "minimal", "low", "medium", "high"), (0, budgets...))
            model = JuliaForever.applythinking(Google(base, id, "synthetic"), level)
            @test model isa Google
            if model isa Google
                @test JuliaForever.stream(model, message, Dict()).done
                expected = level == "off" ? Dict("thinkingBudget" => 0) : Dict("includeThoughts" => true, "thinkingBudget" => budget)
                @test requests[end]["generationConfig"]["thinkingConfig"] == expected
                if haskey(ENV, "PI_SOURCE")
                    source = ENV["PI_SOURCE"]
                    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
                    reference = JSON3.read(read(`node $(joinpath(@__DIR__, "google_thinking_pi.mjs")) $source $id $level`, String), Dict{String, Any})
                    @test expected == reference["generationConfig"]["thinkingConfig"]
                end
            end
        end
    finally
        close(server); wait(server)
    end
end
