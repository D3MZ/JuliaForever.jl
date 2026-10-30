@testset "duplicate model routes match Pi" begin
    requests = []
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        body = JSON3.read(codeunits(String(request.body)))
        push!(requests, (; target=request.target, model=String(body.model), authorization=HTTP.header(request, "Authorization", ""), modelheader=HTTP.header(request, "x-model", "")))
        chunk = JSON3.write((; choices=[(; delta=(; content="fixture response"), finish_reason="stop")]))
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $chunk\n\ndata: [DONE]\n\n")
    end
    try
        mktempdir() do workspace
            agent = joinpath(workspace, "agent")
            mkpath(agent)
            path = joinpath(agent, "models.json")
            base = "http://$(HTTP.server_addr(server))"
            firstmodel = Dict("id" => "alpha", "baseUrl" => base * "/first", "headers" => Dict("x-model" => "first-header"))
            lastmodel = Dict("id" => "alpha", "baseUrl" => base * "/last", "headers" => Dict("x-model" => "last-header"))
            settings = Dict("api" => "openai-completions", "apiKey" => "\$JF_CUSTOM_KEY", "authHeader" => true, "models" => [firstmodel, lastmodel])
            config = Dict("providers" => Dict("fixture" => settings))
            save() = write(path, JSON3.write(config))
            write(joinpath(agent, "auth.json"), JSON3.write((; fixture=(; type="api_key", key="stored-key"))))
            save()

            result = runcli(workspace, ["--provider", "fixture", "--model", "alpha", "--no-session", "hello"])
            @test result.status == 0 && result.output == "fixture response\n"
            @test requests == [(; target="/last/chat/completions", model="alpha", authorization="Bearer stored-key", modelheader="first-header")]
            @test !occursin("stored-key", result.output * result.diagnostics)
            if haskey(ENV, "PI_SOURCE")
                pi = reference(path, "stored")
                @test (String(pi.base), String(pi.auth.headers.Authorization), String(pi.auth.headers["x-model"])) == (base * "/last", "Bearer stored-key", "first-header")
            end

            settings["modelOverrides"] = Dict("alpha" => Dict("headers" => Dict("x-model" => "\$JF_MISSING_KEY")))
            save()
            before = length(requests)
            overwritten = runcli(workspace, ["--provider", "fixture", "--model", "alpha", "--no-session", "hello"])
            @test overwritten.status == 0 && length(requests) == before + 1
            @test requests[end].modelheader == "first-header"
            if haskey(ENV, "PI_SOURCE")
                pi = reference(path, "stored")
                @test pi.auth.ok && pi.auth.headers["x-model"] == "first-header"
            end
            delete!(settings, "modelOverrides")

            settings["headers"] = Dict("x-model" => "\$JF_MISSING_KEY")
            save()
            before = length(requests)
            missing = runcli(workspace, ["--provider", "fixture", "--model", "alpha", "--no-session", "hello"])
            @test missing.status == 2 && length(requests) == before
            if haskey(ENV, "PI_SOURCE")
                pi = reference(path, "stored")
                @test !pi.auth.ok
            end
            delete!(settings, "headers")

            firstmodel["compat"] = Dict("supportsStore" => false)
            save()
            before = length(requests)
            earlier = runcli(workspace, ["--provider", "fixture", "--model", "alpha", "--no-session", "hello"])
            @test earlier.status == 0 && length(requests) == before + 1
            @test requests[end].target == "/last/chat/completions" && requests[end].modelheader == "first-header"

            delete!(firstmodel, "compat")
            lastmodel["compat"] = Dict("supportsStore" => false)
            save()
            before = length(requests)
            unsupported = runcli(workspace, ["--provider", "fixture", "--model", "alpha", "--no-session", "hello"])
            @test unsupported.status == 2 && length(requests) == before

            delete!(lastmodel, "compat")
            delete!(lastmodel, "baseUrl")
            firstmodel["api"] = pop!(settings, "api")
            save()
            inherited = runcli(workspace, ["--provider", "fixture", "--model", "alpha", "--no-session", "hello"])
            @test inherited.status == 0 && length(requests) == before + 1
            @test requests[end] == (; target="/first/chat/completions", model="alpha", authorization="Bearer stored-key", modelheader="first-header")
            if haskey(ENV, "PI_SOURCE")
                pi = reference(path, "stored")
                @test (String(pi.base), String(pi.auth.headers.Authorization), String(pi.auth.headers["x-model"])) == (base * "/first", "Bearer stored-key", "first-header")
            end

            settings["baseUrl"] = base * "/provider"
            save()
            before = length(requests)
            providerbase = runcli(workspace, ["--provider", "fixture", "--model", "alpha", "--no-session", "hello"])
            @test providerbase.status == 0 && length(requests) == before + 1
            @test requests[end].target == "/provider/chat/completions"
            if haskey(ENV, "PI_SOURCE")
                pi = reference(path, "stored")
                @test pi.base == base * "/provider"
            end

            delete!(settings, "baseUrl")
            firstmodel["id"] = "first"
            save()
            before = length(requests)
            sibling = runcli(workspace, ["--provider", "fixture", "--model", "alpha", "--no-session", "hello"])
            @test sibling.status == 0 && length(requests) == before + 1
            @test requests[end] == (; target="/first/chat/completions", model="alpha", authorization="Bearer stored-key", modelheader="last-header")
            if haskey(ENV, "PI_SOURCE")
                pi = reference(path, "stored")
                @test (pi.base, pi.auth.headers["x-model"]) == (base * "/first", "last-header")
            end

            config["providers"] = Dict("OpenAI" => settings)
            save()
            withenv("PI_CODING_AGENT_DIR" => agent, "JF_CUSTOM_KEY" => "fixture-key", "JF_OPENROUTER_DIR" => joinpath(workspace, "openrouter")) do
                registry = JuliaForever.Models.load(path)
                info = JuliaForever.configuredinfo(registry, "OpenAI", "alpha", ENV)
                provider = JuliaForever.acquire(JuliaForever.APIKeyAuth(), info, "alpha")
                @test provider isa JuliaForever.OpenAI
                if provider isa JuliaForever.OpenAI
                    HTTP.post(JuliaForever.endpoint(provider), JuliaForever.headers(provider), JSON3.write((; model="alpha")); status_exception=false, retry=false)
                    @test requests[end] == (; target="/first/chat/completions", model="alpha", authorization="Bearer fixture-key", modelheader="last-header")
                end
            end
            if haskey(ENV, "PI_SOURCE")
                pi = reference(path, "configured"; provider="OpenAI")
                @test (pi.base, pi.auth.headers.Authorization, pi.auth.headers["x-model"]) == (base * "/first", "Bearer fixture-key", "last-header")
            end
        end
    finally
        close(server)
        wait(server)
    end
end

@testset "interactive configured OpenAI selection" begin
    if !Sys.iswindows()
        requests = []
        server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
            body = JSON3.read(codeunits(String(request.body)))
            push!(requests, (; target=request.target, model=String(body.model), authorization=HTTP.header(request, "Authorization", "")))
            delta = JSON3.write((; type="response.output_text.delta", delta="fixture response"))
            output = [(; type="message", content=[(; type="output_text", text="fixture response")])]
            done = JSON3.write((; type="response.completed", response=(; status="completed", output)))
            HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $delta\n\ndata: $done\n\n")
        end
        try
            mktempdir() do workspace
                agent = joinpath(workspace, "agent")
                mkpath(agent)
                path = joinpath(agent, "models.json")
                base = "http://$(HTTP.server_addr(server))"
                settings = Dict("baseUrl" => base * "/tty", "apiKey" => "tty-key")
                config = Dict("providers" => Dict("openai" => settings))
                write(path, JSON3.write(config))
                withenv("OPENAI_MODEL" => "gpt-4.1") do
                    configured = runtty(workspace, ["--no-session"])
                    @test configured.status == 0 && !occursin("Continue with ChatGPT?", configured.diagnostics)
                    @test requests == [(; target="/tty/responses", model="gpt-4.1", authorization="Bearer tty-key")]
                    settings["apiKey"] = "\$JF_MISSING_KEY"
                    write(path, JSON3.write(config))
                    fallback = runtty(workspace, ["--no-session"]; env=["OPENAI_API_KEY" => "unused-env-key"])
                    @test fallback.status == 0 && occursin("Continue with ChatGPT?", fallback.diagnostics)
                    @test length(requests) == 1
                end
            end
        finally
            close(server)
            wait(server)
        end
    end
end
