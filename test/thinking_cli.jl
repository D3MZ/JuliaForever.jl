using Test, JuliaForever, HTTP, JSON3
isdefined(Main, :models_process) || include_string(Main, first(split(read(joinpath(@__DIR__, "terminal_models.jl"), String), "@testset")), joinpath(@__DIR__, "terminal_models.jl"))

@testset "model thinking suffix" begin
    requests = Channel{Any}(10)
    destinations = []
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        push!(destinations, (; target=request.target, authorization=HTTP.header(request, "Authorization", "")))
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
            @test isready(requests)
            if isready(requests)
                body = take!(requests)
                @test body["model"] == "gpt-5.2"
                @test body["reasoning"] == Dict("effort" => "high", "summary" => "auto")
                if haskey(ENV, "PI_SOURCE")
                    source = ENV["PI_SOURCE"]
                    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
                    reference = JSON3.read(read(`node $(joinpath(@__DIR__, "thinking_pi.mjs")) $source`, String), Dict{String, Any})
                    @test body["reasoning"] == reference["reasoning"]
                    @test isempty(reference["updates"])
                    @test reference["exact"] == "gpt-5.2" && reference["suffixed"] === nothing
                    project = dirname(@__DIR__)
                    input = joinpath(source, "node_modules", "@earendil-works", "pi-ai", "dist", "providers", "data", "openai.json")
                    generated = joinpath(workspace, "thinking.json")
                    run(`$(Base.julia_cmd()) --startup-file=no --project=$project $(joinpath(project, "scripts", "openai_thinking.jl")) $input $generated`)
                    @test JSON3.read(read(generated), Dict{String, Any}) == JSON3.read(read(joinpath(project, "data", "openai-thinking.json")), Dict{String, Any})
                end
            end
            off = models_process(base, workspace, ["--model", "openai/gpt-5.2:off", "hello"])
            @test off.status == 0
            @test isready(requests)
            if isready(requests)
                @test take!(requests)["reasoning"] == Dict("effort" => "none")
            end
            missing = models_process(base, workspace, ["--provider", "openai", "--model", "gpt-5.2", "hello"]; openai_key=nothing)
            @test missing.status == 2 && !occursin("MethodError", missing.diagnostics)
            @test !isready(requests)

            session = models_process(base, workspace, ["--model", "openai/gpt-5.2:high", "--no-session"]; input="first\n/model gpt-5.2\nsecond\n/exit\n")
            @test session.status == 0
            @test isready(requests)
            if isready(requests)
                first = take!(requests)
                @test first["model"] == "gpt-5.2" && first["reasoning"]["effort"] == "high"
            end
            @test isready(requests)
            if isready(requests)
                second = take!(requests)
                @test second["model"] == "gpt-5.2" && second["reasoning"]["effort"] == "high"
            end
            @test !occursin("synthetic-openai-secret", session.output * session.diagnostics)
            @test all(item -> item == (; target="/openai/responses", authorization="Bearer synthetic-openai-secret"), destinations[end-1:end])

            switched = models_process(base, workspace, ["--model", "openai/gpt-5.2:high", "--no-session"]; input="first\n/model gpt-5.1\nsecond\n/model gpt-6-luna\nthird\n/exit\n")
            @test switched.status == 2 && occursin("Thinking", switched.diagnostics)
            for expected in ("gpt-5.2", "gpt-5.1", "gpt-5.1")
                @test isready(requests)
                if isready(requests)
                    body = take!(requests)
                    @test body["model"] == expected && body["reasoning"]["effort"] == "high"
                end
            end
            @test all(item -> item == (; target="/openai/responses", authorization="Bearer synthetic-openai-secret"), destinations[end-2:end])
            @test !occursin("synthetic-openai-secret", switched.output * switched.diagnostics)

            suffix = models_process(base, workspace, ["--model", "openai/gpt-5.2:high", "--no-session"]; input="first\n/model gpt-5.2:low\nsecond\n/exit\n")
            @test suffix.status == 2 && occursin("Thinking", suffix.diagnostics)
            @test isready(requests)
            if isready(requests)
                @test take!(requests)["model"] == "gpt-5.2"
            end
            @test isready(requests)
            if isready(requests)
                second = take!(requests)
                @test second["model"] == "gpt-5.2" && second["reasoning"]["effort"] == "high"
            end
            @test all(item -> item == (; target="/openai/responses", authorization="Bearer synthetic-openai-secret"), destinations[end-1:end])
            @test !occursin("synthetic-openai-secret", suffix.output * suffix.diagnostics)

            update = models_process(base, workspace, ["--model", "openai/gpt-6-luna:high", "hello"])
            @test update.status == 2 && occursin("Thinking", update.diagnostics)
            @test !isready(requests)
            while isready(requests)
                take!(requests)
            end
            if haskey(ENV, "PI_SOURCE")
                source = ENV["PI_SOURCE"]
                pi = JSON3.read(read(`node $(joinpath(@__DIR__, "thinking_pi.mjs")) $source gpt-6-luna high`, String), Dict{String, Any})
                @test pi["reasoning"] == Dict("effort" => "medium", "summary" => "auto")
                @test pi["updates"] == [Dict("type" => "configuration_update", "reasoning" => Dict("effort" => "high"))]
            end
            updateoff = models_process(base, workspace, ["--model", "openai/gpt-6-luna:off", "hello"])
            @test updateoff.status == 0 && isready(requests)
            if isready(requests)
                body = take!(requests)
                @test body["reasoning"] == Dict("effort" => "none")
                if haskey(ENV, "PI_SOURCE")
                    source = ENV["PI_SOURCE"]
                    pi = JSON3.read(read(`node $(joinpath(@__DIR__, "thinking_pi.mjs")) $source gpt-6-luna off`, String), Dict{String, Any})
                    @test body["reasoning"] == pi["reasoning"] && isempty(pi["updates"])
                    @test !any(item -> get(item, "type", nothing) == "configuration_update", body["input"])
                end
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
        wait(server)
    end
end
