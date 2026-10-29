using HTTP, JSON3, SHA, Base64

@testset "OpenRouter loopback login" begin
    callback = OpenRouterCallback()
    other = OpenRouterCallback()
    try
        login = authorize(callback)
        params = HTTP.queryparams(HTTP.URI(login.url))
        address = params["callback_url"]
        other_address = HTTP.queryparams(HTTP.URI(authorize(other).url))["callback_url"]
        @test startswith(address, "http://127.0.0.1:")
        @test address != other_address
        @test params["state"] != HTTP.queryparams(HTTP.URI(authorize(other).url))["state"]
        @test params["code_challenge"] == rstrip(replace(base64encode(sha256(login.verifier)), "+" => "-", "/" => "_"), '=')
        @test params["code_challenge_method"] == "S256"
        @test !occursin(login.verifier, login.url)
        @test !occursin(params["state"], sprint(show, callback))

        status(method, url) = HTTP.request(method, url; status_exception=false, redirect=false, retry=false).status
        state = HTTP.escapeuri(params["state"])
        @test status("GET", "$(address)/wrong?code=synthetic&state=$state") == 404
        @test status("POST", "$address?code=synthetic&state=$state") == 405
        @test status("GET", "$address?code=synthetic&state=wrong") == 400
        @test status("GET", "$address?code=synthetic&code=other&state=$state") == 400
        @test status("GET", "$address?code=synthetic&state=$state&state=wrong") == 400
        @test status("GET", "$address?code=synthetic&error=access_denied&state=$state") == 400
        @test status("GET", "$address?code=synthetic%2Bcode&state=$state") == 200
        @test status("GET", "$address?code=other&state=$state") == 409
        @test wait(callback; timeout=1) == "synthetic+code"

        received = Channel{Any}(1)
        server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
            put!(received, (; target=request.target, body=JSON3.read(String(request.body))))
            HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write((; key="synthetic-key")))
        end
        try
            key = exchange(login, "synthetic+code"; base="http://$(HTTP.server_addr(server))/api/v1")
            request = take!(received)
            @test request.target == "/api/v1/auth/keys"
            @test request.body.code == "synthetic+code"
            @test request.body.code_verifier == login.verifier
            @test key == "synthetic-key"
        finally
            close(server)
            wait(server)
        end

        @test status("GET", "$other_address?error=access_denied") == 200
        @test wait(other; timeout=1) === nothing
    finally
        close(callback)
        close(other)
    end
end

@testset "OpenRouter callback timeout" begin
    callback = OpenRouterCallback()
    try
        @test wait(callback; timeout=0.01) === nothing
    finally
        close(callback)
    end
end

@testset "OpenRouter callback CLI" begin
    requests = Channel{Any}(2)
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        body = JSON3.read(String(request.body))
        put!(requests, (; target=request.target, authorization=HTTP.header(request, "Authorization", nothing), body))
        if request.target == "/api/v1/auth/keys"
            HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write((; key="synthetic-key")))
        else
            event = JSON3.write((; choices=[(; delta=(; content="done"), finish_reason="stop")]))
            HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $event\n\ndata: [DONE]\n\n")
        end
    end
    try
        project = dirname(@__DIR__)
        base = "http://$(HTTP.server_addr(server))/api/v1"
        cmd = addenv(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project -m JuliaForever --no-session --login-openrouter-callback hello`, "OPENROUTER_BASE_URL" => base, "OPENROUTER_MODEL" => "fixture/model")
        output = open(cmd, "r") do io
            line = readline(io)
            url = match(r"https://openrouter\.ai/auth\?\S+", line).match
            params = HTTP.queryparams(HTTP.URI(url))
            callback = params["callback_url"]
            state = HTTP.escapeuri(params["state"])
            @test HTTP.get("$callback?code=synthetic-code&state=$state"; redirect=false, retry=false).status == 200
            line * "\n" * read(io, String)
        end
        first, second = take!(requests), take!(requests)
        @test first.target == "/api/v1/auth/keys"
        @test first.body.code == "synthetic-code"
        @test second.authorization == "Bearer synthetic-key"
        @test second.body.model == "fixture/model"
        @test occursin("done", output)
        @test !occursin("synthetic-key", output)
        @test !occursin(first.body.code_verifier, output)
    finally
        close(server)
        wait(server)
    end
end

if haskey(ENV, "PI_SOURCE")
    include("openrouter_differential.jl")
end
