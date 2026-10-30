module ModelOverlaysCLI

using Test, JuliaForever, HTTP, JSON3

function runcli(workspace, args; input="")
    project = dirname(@__DIR__)
    cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever $args`; dir=workspace)
    cmd = fixtureenv(cmd, workspace)
    mktempdir() do dir
        stdinpath, output, diagnostics = joinpath.((dir,), ("stdin", "output", "diagnostics"))
        write(stdinpath, input)
        process = run(pipeline(ignorestatus(cmd); stdin=stdinpath, stdout=output, stderr=diagnostics))
        (; status=process.exitcode, output=read(output, String), diagnostics=read(diagnostics, String))
    end
end

function fixtureenv(cmd, workspace)
    addenv(cmd, "HOME" => workspace, "JULIA_DEPOT_PATH" => join(DEPOT_PATH, Sys.iswindows() ? ';' : ':'), "PI_CODING_AGENT_DIR" => joinpath(workspace, "agent"), "JF_CHATGPT_DIR" => joinpath(workspace, "chatgpt"), "JF_OPENROUTER_DIR" => joinpath(workspace, "openrouter"), "JF_CUSTOM_KEY" => "fixture-key", "JF_CUSTOM_HEADER" => "fixture-header", "JF_MISSING_KEY" => nothing, "JF_PROVIDER" => nothing, "OPENAI_API_KEY" => nothing, "OPENROUTER_API_KEY" => nothing, "ANTHROPIC_API_KEY" => nothing, "GEMINI_API_KEY" => nothing, "JF_INSTRUCTIONS_DIR" => nothing, "TERM" => "dumb")
end

function runtty(workspace, args; env=[])
    script = joinpath(@__DIR__, "model_overlays_tty.py")
    cmd = `python3 $script $(first(Base.julia_cmd().exec)) $(dirname(@__DIR__)) $workspace $args`
    JSON3.read(read(addenv(fixtureenv(cmd, workspace), env...)))
end

function reference(path, mode; provider="fixture", id="alpha")
    script = joinpath(@__DIR__, "model_overlay_auth_pi.mjs")
    cmd = `node --conditions=source --experimental-strip-types $script $(ENV["PI_SOURCE"]) $path $mode $provider $id`
    cmd = addenv(cmd, "JF_CUSTOM_KEY" => "fixture-key", "JF_CUSTOM_HEADER" => "fixture-header", "JF_MISSING_KEY" => nothing)
    JSON3.read(read(cmd))
end

@testset "custom model configuration reaches the CLI transport" begin
    requests = []
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        body = JSON3.read(codeunits(String(request.body)))
        push!(requests, (; target=request.target, model=String(get(body, :model, "")), authorization=HTTP.header(request, "Authorization", ""), providerheader=HTTP.header(request, "x-provider", ""), modelheader=HTTP.header(request, "x-model", ""), anthropic=HTTP.header(request, "x-api-key", ""), google=HTTP.header(request, "x-goog-api-key", "")))
        if endswith(request.target, "/responses")
            delta = JSON3.write((; type="response.output_text.delta", delta="fixture response"))
            output = [(; type="message", content=[(; type="output_text", text="fixture response")])]
            done = JSON3.write((; type="response.completed", response=(; status="completed", output)))
            return HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $delta\n\ndata: $done\n\n")
        end
        if endswith(request.target, "/v1/messages")
            events = [Dict("type" => "message_start", "message" => Dict("usage" => Dict())), Dict("type" => "content_block_start", "index" => 0, "content_block" => Dict("type" => "text", "text" => "fixture response")), Dict("type" => "content_block_stop", "index" => 0), Dict("type" => "message_delta", "delta" => Dict("stop_reason" => "end_turn")), Dict("type" => "message_stop")]
            return HTTP.Response(200, ["Content-Type" => "text/event-stream"], join("data: $(JSON3.write(event))\n\n" for event in events))
        end
        if occursin(":streamGenerateContent", request.target)
            event = Dict("candidates" => [Dict("content" => Dict("parts" => [Dict("text" => "fixture response")]), "finishReason" => "STOP")])
            return HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $(JSON3.write(event))\n\n")
        end
        chunk = JSON3.write((; choices=[(; delta=(; content="fixture response"), finish_reason="stop")]))
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $chunk\n\ndata: [DONE]\n\n")
    end
    try
        mktempdir() do workspace
            agent = joinpath(workspace, "agent")
            mkpath(agent)
            base = "http://$(HTTP.server_addr(server))"
            config = (; providers=(; fixture=(; baseUrl=base * "/provider", api="openai-completions", apiKey="\$JF_CUSTOM_KEY", authHeader=true, headers=Dict("x-provider" => "\${JF_CUSTOM_HEADER}", "x-model" => "provider-header"), models=[(; id="alpha", baseUrl=base * "/model", headers=Dict("x-model" => "fixture-model-header")), (; id="beta", baseUrl=base * "/beta", headers=Dict("x-model" => "beta-header")), (; id="claude-fixture", api="anthropic-messages", baseUrl=base * "/anthropic"), (; id="gemini-fixture", api="google-generative-ai", baseUrl=base * "/google")], modelOverrides=(; alpha=(; name="Custom Alpha", maxTokens=1234, headers=Dict("x-model" => "override-header")))), openai=(; baseUrl=base * "/builtin", apiKey="\$JF_CUSTOM_KEY")))
            json = JSON3.write(config)
            write(joinpath(agent, "models.json"), "\ufeff// configured provider\n" * json[1:end-1] * ",}")

            listed = runcli(workspace, ["--list-models", "fixture alpha"])
            @test listed.status == 0 && occursin("fixture", listed.output) && occursin("alpha", listed.output)

            result = runcli(workspace, ["--provider", "fixture", "--model", "alpha", "--no-session", "hello"])
            @test result.status == 0 && result.output == "fixture response\n"
            @test length(requests) == 1
            if length(requests) == 1
                @test only(requests) == (; target="/model/chat/completions", model="alpha", authorization="Bearer fixture-key", providerheader="fixture-header", modelheader="fixture-model-header", anthropic="", google="")
                if haskey(ENV, "PI_SOURCE")
                    pi = reference(joinpath(agent, "models.json"), "configured")
                    @test (base * only(requests).target, only(requests).model, only(requests).authorization, only(requests).providerheader, only(requests).modelheader) == (String(pi.base) * "/chat/completions", String(pi.id), String(pi.auth.headers.Authorization), String(pi.auth.headers["x-provider"]), String(pi.auth.headers["x-model"]))
                end
            end
            @test !occursin("fixture-key", result.output * result.diagnostics)

            write(joinpath(agent, "auth.json"), JSON3.write((; fixture=(; type="api_key", key="stored-key"))))
            stored = runcli(workspace, ["--model", "fixture/alpha", "--no-session", "hello"])
            @test stored.status == 0 && length(requests) == 2
            if length(requests) == 2
                @test requests[end].authorization == "Bearer stored-key"
                if haskey(ENV, "PI_SOURCE")
                    pi = reference(joinpath(agent, "models.json"), "stored")
                    @test requests[end].authorization == pi.auth.headers.Authorization
                end
            end
            @test !occursin("stored-key", stored.output * stored.diagnostics)

            registry = JuliaForever.Models.load(joinpath(agent, "models.json"))
            @test all(text -> !occursin("fixture-model-header", text), (sprint(show, registry), JSON3.write(registry)))

            switched = runcli(workspace, ["--provider", "fixture", "--model", "alpha", "--no-session"]; input="first\n/model beta\nsecond\n/exit\n")
            @test switched.status == 0 && length(requests) == 4
            if length(requests) == 4
                @test (requests[3].target, requests[4].target, requests[4].model, requests[4].modelheader, requests[4].authorization) == ("/model/chat/completions", "/beta/chat/completions", "beta", "beta-header", "Bearer stored-key")
            end

            builtin = runcli(workspace, ["--provider", "openai", "--model", "gpt-4.1", "--no-session", "hello"])
            @test builtin.status == 0 && length(requests) == 5
            if length(requests) == 5
                @test (requests[end].target, requests[end].model, requests[end].authorization) == ("/builtin/responses", "gpt-4.1", "Bearer fixture-key")
                if haskey(ENV, "PI_SOURCE")
                    pi = reference(joinpath(agent, "models.json"), "configured"; provider="openai", id="gpt-4.1")
                    @test (base * requests[end].target, requests[end].model) == (String(pi.base) * "/responses", String(pi.id))
                end
            end

            anthropic = runcli(workspace, ["--provider", "fixture", "--model", "claude-fixture", "--no-session", "hello"])
            @test anthropic.status == 0 && length(requests) == 6
            if length(requests) == 6
                @test (requests[end].target, requests[end].model, requests[end].anthropic) == ("/anthropic/v1/messages", "claude-fixture", "stored-key")
            end
            google = runcli(workspace, ["--provider", "fixture", "--model", "gemini-fixture", "--no-session", "hello"])
            @test google.status == 0 && length(requests) == 7
            if length(requests) == 7
                @test (requests[end].target, requests[end].google) == ("/google/models/gemini-fixture:streamGenerateContent?alt=sse", "stored-key")
            end
            unknown = runcli(workspace, ["--provider", "openai-responses", "--model", "unknown-model", "--no-session", "hello"])
            @test unknown.status == 0 && length(requests) == 8
            if length(requests) == 8
                @test (requests[end].target, requests[end].model) == ("/builtin/responses", "unknown-model")
            end
            if !Sys.iswindows()
                before = length(requests)
                tty = runtty(workspace, ["--model", "fixture/alpha", "--no-session"])
                @test tty.status == 0 && length(requests) == before + 1
                if length(requests) == before + 1
                    @test (requests[end].target, requests[end].model) == ("/model/chat/completions", "alpha")
                end
            end
            count = length(requests)

            rm(joinpath(agent, "auth.json"))
            missing = JSON3.read(JSON3.write(config), Dict{String, Any})
            missing["providers"]["fixture"]["apiKey"] = "\$JF_MISSING_KEY"
            write(joinpath(agent, "models.json"), JSON3.write(missing))
            rejected = runcli(workspace, ["--provider", "fixture", "--model", "alpha", "--no-session", "hello"])
            @test rejected.status == 2 && length(requests) == count

            missing["providers"]["fixture"]["apiKey"] = "!touch " * joinpath(workspace, "command-ran")
            write(joinpath(agent, "models.json"), JSON3.write(missing))
            command = runcli(workspace, ["--provider", "fixture", "--model", "alpha", "--no-session", "hello"])
            @test command.status == 2 && !isfile(joinpath(workspace, "command-ran")) && length(requests) == count

            write(joinpath(agent, "models.json"), "{\"providers\":{\"fixture\":{\"apiKey\":\"sensitive-probe-secret\",broken}}")
            invalid = runcli(workspace, ["--list-models"])
            @test invalid.status == 2 && !occursin("sensitive-probe-secret", invalid.output * invalid.diagnostics)
        end
    finally
        close(server)
        wait(server)
    end
end

include("model_duplicate_routes.jl")

end
