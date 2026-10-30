module ModelStartup

using Test, JuliaForever, HTTP, JSON3

function runtty(workspace, base, model)
    script = joinpath(@__DIR__, "model_overlays_tty.py")
    project = dirname(@__DIR__)
    cmd = `python3 $script $(first(Base.julia_cmd().exec)) $project $workspace --no-session --model $model`
    cmd = addenv(cmd, "HOME" => workspace, "JULIA_DEPOT_PATH" => join(DEPOT_PATH, Sys.iswindows() ? ';' : ':'), "PI_CODING_AGENT_DIR" => joinpath(workspace, "pi"), "JF_CHATGPT_DIR" => joinpath(workspace, "chatgpt"), "JF_OPENROUTER_DIR" => joinpath(workspace, "router"), "JF_TEST_ABSENT" => nothing, "JF_PROVIDER" => nothing, "OPENAI_API_KEY" => nothing, "OPENROUTER_API_KEY" => nothing, "OPENROUTER_BASE_URL" => base, "ANTHROPIC_API_KEY" => nothing, "GEMINI_API_KEY" => nothing, "JF_INSTRUCTIONS_DIR" => workspace, "TERM" => "dumb")
    JSON3.read(read(cmd, String))
end

@testset "terminal chooses a saved provider for an explicit model" begin
    if Sys.isunix()
        requests = []
        server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
            body = JSON3.read(codeunits(String(request.body)))
            push!(requests, (; model=String(body.model), authorization=HTTP.header(request, "Authorization", "")))
            chunk = JSON3.write((; choices=[(; delta=(; content="fixture reply"), finish_reason="stop")]))
            HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $chunk\n\ndata: [DONE]\n\n")
        end
        try
            mktempdir() do workspace
                agent = joinpath(workspace, "pi")
                mkpath(agent)
                write(joinpath(agent, "auth.json"), JSON3.write((; openrouter=(; type="api_key", key="fixture-router-key"))))
                base = "http://$(HTTP.server_addr(server))/v1"
                models = ("openrouter/free", "openrouter/nvidia/nemotron-3.5-lightning:free")
                for model in models
                    result = runtty(workspace, base, model)
                    @test result.status == 0 && !occursin("Continue with ChatGPT?", result.diagnostics)
                    @test !occursin("fixture-router-key", result.output * result.diagnostics)
                end
                @test requests == [(; model="openrouter/free", authorization="Bearer fixture-router-key"), (; model="nvidia/nemotron-3.5-lightning:free", authorization="Bearer fixture-router-key")]
                chatgpt = runtty(workspace, base, "gpt-6-luna")
                @test chatgpt.status == 0 && occursin("Continue with ChatGPT?", chatgpt.diagnostics)
                @test length(requests) == 2
                config = Dict("providers" => Dict("openrouter" => Dict("api" => "openai-completions", "baseUrl" => base, "apiKey" => "\$JF_TEST_ABSENT")))
                write(joinpath(agent, "models.json"), JSON3.write(config))
                custom = runtty(workspace, base, "openrouter/free")
                @test custom.status == 0 && !occursin("Continue with ChatGPT?", custom.diagnostics)
                @test requests[end] == (; model="openrouter/free", authorization="Bearer fixture-router-key")
                rm(joinpath(agent, "auth.json"))
                missingcustom = runtty(workspace, base, "openrouter/free")
                @test missingcustom.status == 2 && !occursin("Continue with ChatGPT?", missingcustom.diagnostics)
                @test length(requests) == 3
                rm(joinpath(agent, "models.json"))
                missing = runtty(workspace, base, "openrouter/free")
                @test missing.status == 2 && occursin("OPENROUTER_API_KEY", missing.diagnostics) && !occursin("Continue with ChatGPT?", missing.diagnostics)
                @test length(requests) == 3
                if haskey(ENV, "PI_SOURCE")
                    source = ENV["PI_SOURCE"]
                    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
                    script = joinpath(@__DIR__, "model_startup_pi.mjs")
                    reference = JSON3.read(read(`node --conditions=source --experimental-strip-types $script $source $(joinpath(workspace, "missing.json")) $(collect(models))`, String))
                    @test [(row.provider, row.id) for row in reference] == [("openrouter", "openrouter/free"), ("openrouter", "nvidia/nemotron-3.5-lightning:free")]
                end
            end
        finally
            close(server)
            wait(server)
        end
    end
end

end
