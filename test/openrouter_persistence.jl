using Test, JuliaForever, HTTP, JSON3

@testset "OpenRouter login survives restart and signs out locally" begin
    if Sys.isunix()
        requests = Channel{Any}(8)
        server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
            put!(requests, (; target=request.target, authorization=HTTP.header(request, "Authorization", nothing)))
            if request.target == "/api/v1/auth/keys"
                HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write((; key="fixture-router-key")))
            else
                chunk = JSON3.write((; choices=[(; delta=(; content="ok"), finish_reason="stop")]))
                HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $chunk\n\ndata: [DONE]\n\n")
            end
        end
        request() = isready(requests) ? take!(requests) : (; target="", authorization=nothing)
        try
            mktempdir() do root
                auth = joinpath(root, "jf-auth")
                pi = joinpath(root, "pi")
                mkpath(pi)
                pifile = joinpath(pi, "auth.json")
                write(pifile, JSON3.write(Dict("openrouter" => Dict("type" => "api_key", "key" => "fixture-pi-key"))))
                originalpi = read(pifile)
                project = dirname(@__DIR__)
                function cli(args; input="")
                    cmd = `$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever $args`
                    cmd = addenv(cmd, "JF_OPENROUTER_DIR" => auth, "PI_CODING_AGENT_DIR" => pi, "JF_INSTRUCTIONS_DIR" => root, "JF_SESSION_DIR" => joinpath(root, "sessions"), "OPENROUTER_BASE_URL" => "http://$(HTTP.server_addr(server))/api/v1", "OPENROUTER_API_KEY" => "fixture-env-key")
                    inputfile, output, diagnostics = joinpath.((root,), ("input", "out", "err"))
                    write(inputfile, input)
                    process = run(pipeline(ignorestatus(cmd); stdin=inputfile, stdout=output, stderr=diagnostics))
                    (; status=process.exitcode, output=read(output, String), diagnostics=read(diagnostics, String))
                end
                first = cli(["--no-session", "--login-openrouter", "--model", "fixture/model", "hello"]; input="fixture-code\n")
                @test first.status == 0
                @test !occursin("fixture-router-key", first.output * first.diagnostics)
                @test request().target == "/api/v1/auth/keys"
                @test request().authorization == "Bearer fixture-router-key"
                keyfile = joinpath(auth, "key")
                @test isfile(keyfile)
                if isfile(keyfile)
                    @test stat(auth).mode & 0o777 == 0o700
                    @test stat(keyfile).mode & 0o777 == 0o600
                end
                second = cli(["--no-session", "--provider", "openrouter", "--model", "fixture/model", "again"])
                @test second.status == 0
                @test request().authorization == "Bearer fixture-router-key"
                write(joinpath(pi, "models.json"), JSON3.write(Dict("providers" => Dict("openrouter" => Dict("baseUrl" => "http://$(HTTP.server_addr(server))/api/v1")))))
                configured = cli(["--no-session", "--provider", "openrouter", "--model", "fixture/model", "configured"])
                @test configured.status == 0
                @test request().authorization == "Bearer fixture-router-key"
                if isfile(keyfile)
                    chmod(keyfile, 0o644)
                    rejected = cli(["--no-session", "--provider", "openrouter", "--model", "fixture/model", "unsafe"])
                    @test rejected.status != 0
                    @test !isready(requests)
                    chmod(keyfile, 0o600)
                    key = read(keyfile)
                    rm(keyfile)
                    target = joinpath(root, "untouched")
                    write(target, "preserve")
                    symlink(target, keyfile)
                    rejected = cli(["--no-session", "--provider", "openrouter", "--model", "fixture/model", "unsafe"])
                    @test rejected.status != 0 && !isready(requests)
                    unsafe = cli(["--no-session", "--login-openrouter", "--model", "fixture/model", "hello"]; input="fixture-code\n")
                    @test unsafe.status == 0
                    @test occursin("session only", unsafe.diagnostics)
                    @test request().target == "/api/v1/auth/keys"
                    @test request().authorization == "Bearer fixture-router-key"
                    @test cli(["--logout-openrouter"]).status != 0
                    @test islink(keyfile) && read(target, String) == "preserve"
                    rm(keyfile)
                    write(keyfile, key)
                    chmod(keyfile, 0o600)
                end
                logout = cli(["--logout-openrouter"])
                @test logout.status == 0
                @test !ispath(keyfile)
                @test read(pifile) == originalpi
                fallback = cli(["--no-session", "--provider", "openrouter", "--model", "fixture/model", "fallback"])
                @test fallback.status == 0
                @test request().authorization == "Bearer fixture-pi-key"
            end
        finally
            close(server)
            wait(server)
        end
    else
        @test_skip false
    end
end
