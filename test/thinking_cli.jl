using Test, JuliaForever, HTTP, JSON3
isdefined(Main, :models_process) || include_string(Main, first(split(read(joinpath(@__DIR__, "terminal_models.jl"), String), "@testset")), joinpath(@__DIR__, "terminal_models.jl"))

@testset "model thinking suffix" begin
    requests = Channel{Any}(10)
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        put!(requests, JSON3.read(String(request.body), Dict{String, Any}))
        delta = JSON3.write((; type="response.output_text.delta", delta="fixture"))
        done = JSON3.write((; type="response.completed", response=(; status="completed", output=[(; type="message", content=[(; type="output_text", text="fixture")])])))
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $delta\n\ndata: $done\n\n")
    end
    try
        mktempdir() do workspace
            base = "http://$(HTTP.server_addr(server))"
            result = models_process(base, workspace, ["--model", "openai/gpt-5.2:high", "hello"])
            @test result.status == 0
            if result.status == 0
                body = take!(requests)
                @test body["model"] == "gpt-5.2"
                @test body["reasoning"] == Dict("effort" => "high", "summary" => "auto")
                if haskey(ENV, "PI_SOURCE")
                    source = ENV["PI_SOURCE"]
                    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
                    reference = JSON3.read(read(`node $(joinpath(@__DIR__, "thinking_pi.mjs")) $source`, String), Dict{String, Any})
                    @test body["reasoning"] == reference
                end
            end
            off = models_process(base, workspace, ["--model", "openai/gpt-5.2:off", "hello"])
            @test off.status == 0
            if off.status == 0
                @test take!(requests)["reasoning"] == Dict("effort" => "none")
            end
            for model in ("openai/gpt-5.2:minimal", "anthropic/claude-sonnet-4-20250514:high", "openai/unknown:high", "unmatched-synthetic:high")
                result = models_process(base, workspace, ["--model", model, "hello"])
                @test result.status == 2
                @test occursin("Thinking", result.diagnostics)
                @test !isready(requests)
            end
            plan = models_process(base, workspace, ["--login-chatgpt", "--model", "gpt-5.2:high", "hello"])
            @test plan.status == 2
            @test occursin("Thinking", plan.diagnostics)
            @test !isready(requests)
            mkpath(joinpath(workspace, "pi-agent"))
            write(joinpath(workspace, "pi-agent", "models.json"), JSON3.write(Dict("providers" => Dict("openai" => Dict("modelOverrides" => Dict("gpt-5.2" => Dict("thinkingLevelMap" => Dict("high" => "high"))))))))
            configured = models_process(base, workspace, ["--model", "openai/gpt-5.2:high", "hello"])
            @test configured.status == 2
            @test !isready(requests)
        end
    finally
        close(server)
    end
end
