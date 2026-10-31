module ModelStartup

using Test, JuliaForever, HTTP, JSON3

function runtty(workspace, base, model)
    script = joinpath(@__DIR__, "model_overlays_tty.py")
    project = dirname(@__DIR__)
    cmd = `python3 $script $(first(Base.julia_cmd().exec)) $project $workspace --no-session --model $model`
    cmd = addenv(cmd, "HOME" => workspace, "JULIA_DEPOT_PATH" => join(DEPOT_PATH, Sys.iswindows() ? ';' : ':'), "PI_CODING_AGENT_DIR" => joinpath(workspace, "pi"), "JF_CHATGPT_DIR" => joinpath(workspace, "chatgpt"), "JF_OPENROUTER_DIR" => joinpath(workspace, "router"), "JF_TEST_ABSENT" => nothing, "JF_PROVIDER" => nothing, "OPENAI_API_KEY" => nothing, "OPENROUTER_API_KEY" => nothing, "OPENROUTER_BASE_URL" => base, "ANTHROPIC_API_KEY" => nothing, "GEMINI_API_KEY" => nothing, "JF_INSTRUCTIONS_DIR" => workspace, "TERM" => "dumb")
    JSON3.read(read(cmd, String))
end

if haskey(ENV, "PI_SOURCE") && Sys.isunix()
    @testset "saved provider selection against Pi" begin
        requests = []
        server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
            body = JSON3.read(codeunits(String(request.body)))
            push!(requests, String(body.model))
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
                    @test runtty(workspace, base, model).status == 0
                end
                source = ENV["PI_SOURCE"]
                @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
                script = joinpath(@__DIR__, "model_startup_pi.mjs")
                reference = JSON3.read(read(`node --conditions=source --experimental-strip-types $script $source $(joinpath(workspace, "missing.json")) $(collect(models))`, String))
                @test [("openrouter", model) for model in requests] == [(String(row.provider), String(row.id)) for row in reference]
            end
        finally
            close(server)
            wait(server)
        end
    end
end

end
