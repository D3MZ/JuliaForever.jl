using Test, JuliaForever, HTTP, JSON3

function models_process(base, workspace, args; provider="openrouter", openai_model="env-openai", router_model="env/router", openai_key="synthetic-openai-secret", router_key="synthetic-router-secret", anthropic_model="env-anthropic", google_model="env-google", input="")
    project = dirname(@__DIR__)
    cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever $args`; dir=workspace)
    cmd = addenv(cmd, "HOME" => workspace, "PI_CODING_AGENT_DIR" => joinpath(workspace, "pi-agent"), "JF_PROVIDER" => provider, "OPENAI_BASE_URL" => "$base/openai", "OPENAI_MODEL" => openai_model, "OPENAI_API_KEY" => openai_key, "OPENROUTER_BASE_URL" => "$base/router", "OPENROUTER_MODEL" => router_model, "OPENROUTER_API_KEY" => router_key, "ANTHROPIC_BASE_URL" => "$base/anthropic", "ANTHROPIC_MODEL" => anthropic_model, "ANTHROPIC_API_KEY" => "synthetic-anthropic-secret", "GEMINI_BASE_URL" => "$base/google", "GEMINI_MODEL" => google_model, "GEMINI_API_KEY" => "synthetic-google-secret", "JF_SESSION_DIR" => joinpath(workspace, "sessions"), "JF_INSTRUCTIONS_DIR" => workspace, "JF_TEST_PLUGIN" => nothing, "JF_TEST_EVENTS" => nothing)
    mktempdir() do dir
        cmd = addenv(cmd, "JF_OPENROUTER_DIR" => joinpath(dir, "router"))
        stdinpath, stdoutpath, stderrpath = joinpath.((dir,), ("stdin", "stdout", "stderr"))
        write(stdinpath, input)
        process = run(pipeline(ignorestatus(cmd); stdin=stdinpath, stdout=stdoutpath, stderr=stderrpath))
        (; status=process.exitcode, output=read(stdoutpath, String), diagnostics=read(stderrpath, String))
    end
end

@testset "CLI provider and model selection against Pi" begin
    if haskey(ENV, "PI_SOURCE")
        requests = Any[]
        server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
            push!(requests, JSON3.read(String(request.body)))
            chunk = JSON3.write((; choices=[(; delta=(; content="fixture"), finish_reason="stop")]))
            HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $chunk\n\ndata: [DONE]\n\n")
        end
        try
            base = "http://$(HTTP.server_addr(server))"
            mktempdir() do workspace
                @test models_process(base, workspace, ["--provider", "openai", "--model", "chat-cli", "hello"]; openai_model=nothing).status == 0
                @test models_process(base, workspace, ["--model", "vendor/cli", "--provider", "openrouter", "hello"]; provider="openai", router_model=nothing).status == 0
                @test models_process(base, workspace, ["--provider", "openai", "--provider", "openrouter", "--model", "first", "--model", "last", "hello"]).status == 0
                source = ENV["PI_SOURCE"]
                @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
                script = joinpath(@__DIR__, "terminal_models_pi.mjs")
                reference = JSON3.read(read(`node --conditions=source --experimental-strip-types $script $source`, String))
                for (index, provider) in enumerate(("openai", "openrouter", "openrouter"))
                    @test (reference[index].provider, reference[index].model, reference[index].messages[1]) == (provider, requests[index].model, requests[index].messages[end].content)
                end
            end
        finally
            close(server)
            wait(server)
        end
    end
end
