using Test, JuliaForever, HTTP, JSON3

function models_process(base, workspace, args; provider="openrouter", openai_model="env-openai", router_model="env/router", openai_key="synthetic-openai-secret", router_key="synthetic-router-secret", anthropic_model="env-anthropic", google_model="env-google", input="")
    project = dirname(@__DIR__)
    cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever $args`; dir=workspace)
    cmd = addenv(cmd, "HOME" => workspace, "PI_CODING_AGENT_DIR" => joinpath(workspace, "pi-agent"), "JF_PROVIDER" => provider, "OPENAI_BASE_URL" => "$base/openai", "OPENAI_MODEL" => openai_model, "OPENAI_API_KEY" => openai_key, "OPENROUTER_BASE_URL" => "$base/router", "OPENROUTER_MODEL" => router_model, "OPENROUTER_API_KEY" => router_key, "ANTHROPIC_BASE_URL" => "$base/anthropic", "ANTHROPIC_MODEL" => anthropic_model, "ANTHROPIC_API_KEY" => "synthetic-anthropic-secret", "GEMINI_BASE_URL" => "$base/google", "GEMINI_MODEL" => google_model, "GEMINI_API_KEY" => "synthetic-google-secret", "JF_SESSION_DIR" => joinpath(workspace, "sessions"), "JF_INSTRUCTIONS_DIR" => workspace, "JF_TEST_PLUGIN" => nothing, "JF_TEST_EVENTS" => nothing)
    mktempdir() do dir
        stdinpath, stdoutpath, stderrpath = joinpath.((dir,), ("stdin", "stdout", "stderr"))
        write(stdinpath, input)
        process = run(pipeline(ignorestatus(cmd); stdin=stdinpath, stdout=stdoutpath, stderr=stderrpath))
        (; status=process.exitcode, output=read(stdoutpath, String), diagnostics=read(stderrpath, String))
    end
end

@testset "CLI provider and model selection" begin
    requests = Any[]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        body = JSON3.read(String(request.body))
        push!(requests, (; target=request.target, authorization=HTTP.header(request, "Authorization", nothing), anthropic_key=HTTP.header(request, "x-api-key", nothing), google_key=HTTP.header(request, "x-goog-api-key", nothing), body))
        if request.target == "/anthropic/v1/messages"
            events = [Dict("type" => "message_start", "message" => Dict("usage" => Dict())), Dict("type" => "content_block_start", "index" => 0, "content_block" => Dict("type" => "text", "text" => "fixture")), Dict("type" => "content_block_stop", "index" => 0), Dict("type" => "message_delta", "delta" => Dict("stop_reason" => "end_turn")), Dict("type" => "message_stop")]
            return HTTP.Response(200, ["Content-Type" => "text/event-stream"], join("data: $(JSON3.write(event))\n\n" for event in events))
        end
        if startswith(request.target, "/google/models/")
            event = Dict("candidates" => [Dict("content" => Dict("parts" => [Dict("text" => "fixture")]), "finishReason" => "STOP")])
            return HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $(JSON3.write(event))\n\n")
        end
        if request.target == "/router/auth/keys"
            body.code == "synthetic-empty" && return HTTP.Response(200, ["Content-Type" => "application/json"], "{}")
            body.code == "synthetic-malformed" && return HTTP.Response(200, ["Content-Type" => "application/json"], "{synthetic-login-secret")
            body.code == "synthetic-http" && return HTTP.Response(401, ["Content-Type" => "application/json"], "synthetic-login-secret")
            return HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write((; key="synthetic-login-secret")))
        end
        if request.target != "/router/auth/keys" && haskey(body, :messages) && body.messages[end].content == "deny"
            return HTTP.Response(401, ["Content-Type" => "application/json"], "synthetic-router-secret")
        end
        if request.target == "/openai/responses"
            delta = JSON3.write((; type="response.output_text.delta", delta="fixture"))
            output = [(; type="message", content=[(; type="output_text", text="fixture")])]
            done = JSON3.write((; type="response.completed", response=(; status="completed", output)))
            return HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $delta\n\ndata: $done\n\n")
        end
        chunk = JSON3.write((; choices=[(; delta=(; content="fixture"), finish_reason="stop")]))
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $chunk\n\ndata: [DONE]\n\n")
    end
    try
        base = "http://$(HTTP.server_addr(server))"
        mktempdir() do workspace
            ok = (; status=0, output="fixture\n", diagnostics="")
            chat = models_process(base, workspace, ["--provider", "openai", "--model", "chat-cli", "hello"]; openai_model=nothing)
            @test chat == ok
            @test (requests[end].target, requests[end].body.model, requests[end].authorization) == ("/openai/chat/completions", "chat-cli", "Bearer synthetic-openai-secret")

            responses = models_process(base, workspace, ["--provider", "openai-responses", "hello"])
            @test responses == ok
            @test (requests[end].target, requests[end].body.model, requests[end].authorization) == ("/openai/responses", "env-openai", "Bearer synthetic-openai-secret")

            router = models_process(base, workspace, ["--model", "vendor/cli", "--provider", "openrouter", "hello"]; provider="openai", router_model=nothing)
            @test router == ok
            @test (requests[end].target, requests[end].body.model, requests[end].authorization) == ("/router/chat/completions", "vendor/cli", "Bearer synthetic-router-secret")
            override = models_process(base, workspace, ["--model", "only/cli", "hello"])
            @test override == ok
            @test requests[end].body.model == "only/cli"
            defaults = models_process(base, workspace, ["hello"])
            @test defaults == ok
            @test requests[end].body.model == "env/router"
            repeated = models_process(base, workspace, ["--provider", "openai", "--provider", "openrouter", "--model", "first", "--model", "last", "hello"])
            @test repeated == ok
            @test (requests[end].target, requests[end].body.model) == ("/router/chat/completions", "last")

            fallback = models_process(base, workspace, ["--model", "default-cli", "hello"]; provider=nothing)
            @test fallback == ok
            @test (requests[end].target, requests[end].body.model) == ("/openai/chat/completions", "default-cli")
            replaced = models_process(base, workspace, ["--provider", "openai", "hello"]; provider="unknown")
            @test replaced == ok
            @test requests[end].body.model == "env-openai"

            path = joinpath(workspace, "history.sqlite")
            fixture = joinpath(@__DIR__, "fixtures")
            code = models_process(base, workspace, ["--provider", "openai", "--plugin-env", fixture, "--codemode", "--plugin", "GreetingPlugin", "--model", "code-model", "hello"])
            @test code == ok
            @test any(tool -> tool.function.name == "codemode", requests[end].body.tools)
            first = models_process(base, workspace, ["--history", path, "--provider", "openai", "--model", "chat-history", "first"])
            @test first == ok
            second = models_process(base, workspace, ["--plugin-env", fixture, "--provider", "openai-responses", "--plugin", "GreetingPlugin", "--model", "responses-history", "--history", path, "second"])
            @test second == ok
            resumed = requests[end].body
            @test resumed.model == "responses-history"
            @test any(tool -> tool.name == "greet", resumed.tools)
            @test [item.content for item in resumed.input if haskey(item, :role) && item.role in ("user", "assistant")] == ["first", "fixture", "second"]
            @test !occursin("synthetic-openai-secret", String(read(path)))
            @test !occursin("synthetic-router-secret", String(read(path)))

            login = models_process(base, workspace, ["--login-openrouter", "--provider", "openrouter", "--model", "login/model", "hello"]; provider="openai", router_model=nothing, router_key=nothing, input="synthetic-code\n")
            @test login.status == 0
            @test occursin("Open this URL", login.output)
            @test endswith(login.output, "fixture\n")
            @test requests[end-1].target == "/router/auth/keys"
            @test requests[end-1].body.code == "synthetic-code"
            @test (requests[end].target, requests[end].body.model, requests[end].authorization) == ("/router/chat/completions", "login/model", "Bearer synthetic-login-secret")
            for secret in ("synthetic-code", "synthetic-login-secret", "synthetic-openai-secret", "synthetic-router-secret", requests[end-1].body.code_verifier)
                @test !occursin(secret, login.output * login.diagnostics)
            end

            jsonlogin = models_process(base, workspace, ["--mode", "json", "--login-openrouter", "--model", "login/model", "hello"]; provider="openai", router_model=nothing, router_key=nothing, input="synthetic-code\n")
            @test jsonlogin.status == 0
            @test JSON3.read.(split(chomp(jsonlogin.output), '\n'))[1].type == "session"
            @test occursin("Open this URL", jsonlogin.diagnostics)
            @test !occursin("synthetic-code", jsonlogin.output * jsonlogin.diagnostics)

            for (code, status, diagnostic) in (("synthetic-empty", 2, "did not return an API key"), ("synthetic-malformed", 1, "invalid provider response"), ("synthetic-http", 1, "HTTP 401"))
                before = length(requests)
                failed = models_process(base, workspace, ["--login-openrouter", "--model", "login/model", "hello"]; router_key=nothing, input=code * "\n")
                @test failed.status == status
                @test occursin(diagnostic, failed.diagnostics)
                @test length(requests) == before + 1
                @test requests[end].target == "/router/auth/keys"
                for secret in (code, "synthetic-login-secret", requests[end].body.code_verifier)
                    @test !occursin(secret, failed.output * failed.diagnostics)
                end
            end

            denied = models_process(base, workspace, ["--provider", "openrouter", "--model", "vendor/cli", "deny"])
            @test denied.status == 1
            @test occursin("HTTP 401", denied.diagnostics)
            @test !occursin("synthetic-router-secret", denied.output * denied.diagnostics)

            anthropic = models_process(base, workspace, ["--provider", "anthropic", "--model", "cli-anthropic", "hello"]; provider="google", anthropic_model=nothing)
            @test anthropic == ok
            @test (requests[end].target, requests[end].body.model, requests[end].anthropic_key) == ("/anthropic/v1/messages", "cli-anthropic", "synthetic-anthropic-secret")
            google = models_process(base, workspace, ["--provider", "google", "--model", "cli-google", "hello"]; provider="anthropic", google_model=nothing)
            @test google == ok
            @test requests[end].target == "/google/models/cli-google:streamGenerateContent?alt=sse"
            @test requests[end].google_key == "synthetic-google-secret"

            before = length(requests)
            for args in (["--provider"], ["--model"], ["--model", "--history", path], ["--provider", "--model", "unused"], ["--provider", ""], ["--model", "  "], ["--provider", "synthetic-openai-secret", "hello"], ["--provider", "openai", "--login-openrouter", "hello"], ["--login-openrouter", "--login-openrouter-callback", "hello"], ["--login-openrouter-callback", "--login-openrouter", "hello"])
                result = models_process(base, workspace, args)
                @test result.status == 2
                @test !occursin("synthetic-openai-secret", result.output * result.diagnostics)
                @test !occursin("synthetic-router-secret", result.output * result.diagnostics)
            end
            no_model = models_process(base, workspace, ["--provider", "openai", "hello"]; openai_model=nothing)
            @test no_model.status == 2
            @test occursin("OPENAI_MODEL", no_model.diagnostics)
            no_key = models_process(base, workspace, ["--provider", "openai", "--model", "supplied", "hello"]; openai_key=nothing)
            @test no_key.status == 2
            @test occursin("OPENAI_API_KEY", no_key.diagnostics)
            @test length(requests) == before
            inspected = models_process(base, workspace, ["--provider", "openai", "--model", "chosen", "--history", path, "--inspect-history"]; openai_key=nothing)
            @test inspected.status == 0
            @test length(requests) == before

            if haskey(ENV, "PI_SOURCE")
                source = ENV["PI_SOURCE"]
                @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
                script = joinpath(@__DIR__, "terminal_models_pi.mjs")
                reference = JSON3.read(read(`node --conditions=source --experimental-strip-types $script $source`, String))
                @test (reference[1].provider, reference[1].model, reference[1].messages[1]) == ("openai", requests[1].body.model, requests[1].body.messages[end].content)
                @test (reference[2].provider, reference[2].model, reference[2].messages[1]) == ("openrouter", requests[3].body.model, requests[3].body.messages[end].content)
                @test (reference[3].provider, reference[3].model, reference[3].messages[1]) == ("openrouter", requests[6].body.model, requests[6].body.messages[end].content)
            end
        end
    finally
        close(server)
        wait(server)
    end
end
