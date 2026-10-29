@testset "Pi OpenRouter login" begin
    source = ENV["PI_SOURCE"]
    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    command = addenv(`node $(joinpath(@__DIR__, "openrouter_reference.mjs")) $source`, "PI_OAUTH_CALLBACK_HOST" => "127.0.0.1")
    reference = JSON3.read(read(command, String))
    callback = OpenRouterCallback()
    try
        login = authorize(callback)
        params = HTTP.queryparams(HTTP.URI(login.url))
        @test HTTP.URI(params["callback_url"]).host == reference.callback_host
        @test params["code_challenge"] == rstrip(replace(base64encode(sha256(login.verifier)), "+" => "-", "/" => "_"), '=')
        @test reference.challenge_matches
        @test params["code_challenge_method"] == reference.challenge_method == reference.exchange_method
        @test reference.exchange_url == "https://openrouter.ai/api/v1/auth/keys"
        received = Channel{Any}(1)
        server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
            put!(received, (; target=request.target, body=JSON3.read(String(request.body))))
            HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write((; key="synthetic-key")))
        end
        try
            @test exchange(login, "synthetic-code"; base="http://$(HTTP.server_addr(server))/api/v1") == reference.key
            request = take!(received)
            @test request.target == "/api/v1/auth/keys"
            @test request.body.code == reference.code
            @test request.body.code_verifier == login.verifier
            @test request.body.code_challenge_method == reference.exchange_method
        finally
            close(server)
            wait(server)
        end
    finally
        close(callback)
    end
end
