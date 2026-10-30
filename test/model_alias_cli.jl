module ModelAliasCLI

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
    addenv(cmd, "HOME" => workspace, "JULIA_DEPOT_PATH" => join(DEPOT_PATH, Sys.iswindows() ? ';' : ':'), "PI_CODING_AGENT_DIR" => joinpath(workspace, "agent"), "JF_CHATGPT_DIR" => joinpath(workspace, "chatgpt"), "JF_OPENROUTER_DIR" => joinpath(workspace, "openrouter"), "JF_PROVIDER" => nothing, "OPENAI_API_KEY" => nothing, "OPENAI_BASE_URL" => nothing, "OPENROUTER_API_KEY" => nothing, "ANTHROPIC_API_KEY" => nothing, "GEMINI_API_KEY" => nothing, "JF_INSTRUCTIONS_DIR" => nothing, "TERM" => "dumb")
end

function runtty(workspace, args)
    script = joinpath(@__DIR__, "model_overlays_tty.py")
    cmd = `python3 $script $(first(Base.julia_cmd().exec)) $(dirname(@__DIR__)) $workspace $args`
    JSON3.read(read(fixtureenv(cmd, workspace)))
end

function reference(path)
    source = ENV["PI_SOURCE"]
    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    script = joinpath(@__DIR__, "model_overlay_auth_pi.mjs")
    JSON3.read(read(`node --conditions=source --experimental-strip-types $script $source $path configured openai-responses private`))
end

@testset "custom provider named like an OpenAI adapter keeps its own route" begin
    requests = []
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        body = JSON3.read(String(request.body))
        push!(requests, (; target=request.target, model=String(get(body, :model, "")), authorization=HTTP.header(request, "Authorization", "")))
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
            base = "http://$(HTTP.server_addr(server))"
            path = joinpath(agent, "models.json")
            config = Dict("providers" => Dict(
                "openai" => Dict("baseUrl" => base * "/openai", "apiKey" => "openai-key"),
                "openai-responses" => Dict("baseUrl" => base * "/private", "api" => "openai-completions", "apiKey" => "private-key", "models" => [Dict("id" => "private"), Dict("id" => "other")]),
            ))
            write(path, JSON3.write(config))
            registry = JuliaForever.Models.load(path)
            current = JuliaForever.OpenAI(base * "/private", "private", "private-key", Pair{String, String}[], JuliaForever.CatalogRoute("openai-responses", registry))
            session = (; view=(; provider="openai-responses"))
            @test Set(model.id for model in JuliaForever.LiveTerminal.modeloptions(session, current)) == Set(["private", "other"])

            result = runcli(workspace, ["--model", "openai-responses/private", "--no-session", "hello"])
            @test result.status == 0 && result.output == "fixture response\n"
            @test length(requests) == 1
            if length(requests) == 1
                @test only(requests) == (; target="/private/chat/completions", model="private", authorization="Bearer private-key")
                if haskey(ENV, "PI_SOURCE")
                    pi = reference(path)
                    @test (base * only(requests).target, only(requests).model, only(requests).authorization) == (String(pi.base) * "/chat/completions", String(pi.id), "Bearer " * String(pi.auth.apiKey))
                end
            end

            write(joinpath(agent, "auth.json"), JSON3.write(Dict("openai" => Dict("type" => "api_key", "key" => "openai-stored"), "openai-responses" => Dict("type" => "api_key", "key" => "private-stored"))))
            explicit = runcli(workspace, ["--provider", "openai-responses", "--model", "private", "--no-session", "hello"])
            @test explicit.status == 0 && length(requests) == 2
            if length(requests) == 2
                @test requests[end] == (; target="/private/chat/completions", model="private", authorization="Bearer private-stored")
            end

            builtin = runcli(workspace, ["--model", "openai/gpt-4.1", "--no-session", "hello"])
            @test builtin.status == 0 && length(requests) == 3
            if length(requests) == 3
                @test requests[end] == (; target="/openai/responses", model="gpt-4.1", authorization="Bearer openai-stored")
            end

            switched = runcli(workspace, ["--provider", "openai-responses", "--model", "private", "--no-session"]; input="first\n/model other\nsecond\n/exit\n")
            @test switched.status == 0 && length(requests) == 5
            if length(requests) == 5
                @test requests[4].target == "/private/chat/completions"
                @test requests[5] == (; target="/private/chat/completions", model="other", authorization="Bearer private-stored")
            end
            if !Sys.iswindows()
                before = length(requests)
                tty = runtty(workspace, ["--model", "openai-responses/private", "--no-session"])
                @test tty.status == 0 && length(requests) == before + 1
                if length(requests) == before + 1
                    @test requests[end] == (; target="/private/chat/completions", model="private", authorization="Bearer private-stored")
                end
            end

            delete!(config["providers"], "openai")
            config["providers"]["openai-responses"]["apiKey"] = "\$JF_MISSING_KEY"
            write(path, JSON3.write(config))
            write(joinpath(agent, "auth.json"), JSON3.write(Dict("openai-responses" => Dict("type" => "api_key", "key" => "private-stored"))))
            listed = runcli(workspace, ["--list-models", "openai-responses/private"])
            @test listed.status == 0 && occursin("private", listed.output)
        end
    finally
        close(server)
        wait(server)
    end
end

end
