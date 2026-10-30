module ModelValidation

using Test, JuliaForever, HTTP, JSON3

function runcli(workspace, args)
    project = dirname(@__DIR__)
    cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever $args`; dir=workspace)
    cmd = addenv(cmd, "HOME" => workspace, "JULIA_DEPOT_PATH" => join(DEPOT_PATH, Sys.iswindows() ? ';' : ':'), "PI_CODING_AGENT_DIR" => joinpath(workspace, "agent"), "JF_CHATGPT_DIR" => joinpath(workspace, "chatgpt"), "JF_OPENROUTER_DIR" => joinpath(workspace, "openrouter"), "JF_PROVIDER" => nothing, "OPENAI_API_KEY" => nothing, "OPENROUTER_API_KEY" => nothing, "ANTHROPIC_API_KEY" => nothing, "GEMINI_API_KEY" => nothing, "JF_INSTRUCTIONS_DIR" => nothing, "TERM" => "dumb")
    mktempdir() do root
        output, diagnostics = joinpath.((root,), ("output", "diagnostics"))
        process = run(pipeline(ignorestatus(cmd); stdout=output, stderr=diagnostics))
        (; status=process.exitcode, output=read(output, String), diagnostics=read(diagnostics, String))
    end
end

function reference(path, provider, id)
    script = joinpath(@__DIR__, "model_validation_pi.mjs")
    JSON3.read(read(`node --conditions=source --experimental-strip-types $script $(ENV["PI_SOURCE"]) $path $provider $id`))
end

function fixture(base, field, value)
    model = Dict{String, Any}("id" => "alpha")
    overrides = Dict{String, Any}()
    if field == :model
        model["reasoning"] = value
    else
        overrides["alpha"] = Dict("reasoning" => value)
    end
    Dict("providers" => Dict("fixture" => Dict("baseUrl" => base * "/fixture", "api" => "openai-completions", "apiKey" => "synthetic-model-secret", "models" => [model], "modelOverrides" => overrides)))
end

@testset "configured model validation at the CLI boundary" begin
    requests = []
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        body = JSON3.read(codeunits(String(request.body)))
        push!(requests, (; target=request.target, model=String(body.model)))
        if endswith(request.target, "/responses")
            delta = JSON3.write((; type="response.output_text.delta", delta="fixture response"))
            output = [(; type="message", content=[(; type="output_text", text="fixture response")])]
            done = JSON3.write((; type="response.completed", response=(; status="completed", output)))
            return HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $delta\n\ndata: $done\n\n")
        end
        chunk = JSON3.write((; choices=[(; delta=(; content="fixture response"), finish_reason="stop")]))
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $chunk\n\ndata: [DONE]\n\n")
    end
    try
        mktempdir() do workspace
            agent = joinpath(workspace, "agent")
            mkpath(agent)
            path = joinpath(agent, "models.json")
            base = "http://$(HTTP.server_addr(server))"
            secret = "synthetic-model-secret"
            unknown = "model-not-in-snapshot-57931"
            if haskey(ENV, "PI_SOURCE")
                @test readchomp(`git -C $(ENV["PI_SOURCE"]) rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
            end

            @testset "unknown built-in model respects its configured API" begin
                for (api, target) in ((nothing, "/configured/chat/completions"), ("openai-completions", "/configured/chat/completions"), ("openai-responses", "/configured/responses"))
                    settings = Dict{String, Any}("baseUrl" => base * "/configured", "apiKey" => secret)
                    isnothing(api) || (settings["api"] = api)
                    write(path, JSON3.write(Dict("providers" => Dict("openai" => settings))))
                    before = length(requests)
                    result = runcli(workspace, ["--provider", "openai", "--model", unknown, "--no-session", "hello"])
                    @test result.status == 0 && result.output == "fixture response\n"
                    @test length(requests) == before + 1
                    if length(requests) == before + 1
                        @test requests[end] == (; target, model=unknown)
                    end
                    @test !occursin(secret, result.output * result.diagnostics)
                    if isnothing(api) && haskey(ENV, "PI_SOURCE")
                        pi = reference(path, "openai", unknown)
                        @test pi.valid && pi.id == unknown && pi.api == "openai-responses"
                    end
                end
                settings = Dict("baseUrl" => base * "/configured", "api" => "unimplemented-api", "apiKey" => secret)
                write(path, JSON3.write(Dict("providers" => Dict("openai" => settings))))
                before = length(requests)
                result = runcli(workspace, ["--provider", "openai", "--model", unknown, "--no-session", "hello"])
                @test result.status == 2 && length(requests) == before
                @test occursin("Model configuration is invalid", result.diagnostics) && !occursin(secret, result.output * result.diagnostics)
                if haskey(ENV, "PI_SOURCE")
                    pi = reference(path, "openai", unknown)
                    # Pi inherits its default built-in API here; JuliaForever fails closed for an explicitly unsupported API.
                    @test pi.valid && pi.id == unknown && pi.api == "openai-responses"
                end
                known = runcli(workspace, ["--provider", "openai", "--model", "gpt-4.1", "--no-session", "hello"])
                @test known.status == 0 && length(requests) == before + 1
                if length(requests) == before + 1
                    @test requests[end] == (; target="/configured/responses", model="gpt-4.1")
                end
            end

            @testset "reasoning is a boolean in definitions and overrides" begin
                for field in (:model, :override), value in (1, 0, "true", nothing)
                    write(path, JSON3.write(fixture(base, field, value)))
                    @test JuliaForever.Models.load(path) isa JuliaForever.Models.InvalidConfig
                    if haskey(ENV, "PI_SOURCE")
                        @test !reference(path, "fixture", "alpha").valid
                    end
                    if value === 1
                        before = length(requests)
                        result = runcli(workspace, ["--provider", "fixture", "--model", "alpha", "--no-session", "hello"])
                        @test result.status == 2 && length(requests) == before
                        @test !occursin(secret, result.output * result.diagnostics)
                    end
                end
                for (field, value) in ((:model, true), (:override, false))
                    write(path, JSON3.write(fixture(base, field, value)))
                    before = length(requests)
                    result = runcli(workspace, ["--provider", "fixture", "--model", "alpha", "--no-session", "hello"])
                    @test result.status == 0 && result.output == "fixture response\n" && length(requests) == before + 1
                    if length(requests) == before + 1
                        @test requests[end] == (; target="/fixture/chat/completions", model="alpha")
                    end
                    registry = JuliaForever.Models.load(path)
                    model = JuliaForever.Models.findmodel(candidate -> candidate.provider == "fixture" && candidate.id == "alpha", registry.models)
                    @test model.reasoning === value
                    if haskey(ENV, "PI_SOURCE")
                        pi = reference(path, "fixture", "alpha")
                        @test pi.valid && pi.reasoning === value
                    end
                end
            end
        end
    finally
        close(server)
        wait(server)
    end
end

end
