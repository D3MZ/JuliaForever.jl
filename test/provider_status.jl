using Test, JuliaForever, HTTP, JSON3

@testset "provider status contains no credentials" begin
    secret = "synthetic-bearer-secret"
    for model in (OpenAI("https://user:$secret@example.test/v1", "test", secret), OpenAIResponses("https://user:$secret@example.test/v1", "test", secret))
        @test !occursin(secret, sprint(show, model))
        @test !occursin(secret, JSON3.write((; model)))
    end
    status = Ref(401)
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        HTTP.Response(status[], ["Content-Type" => "application/json", "Location" => "/elsewhere"], "{\"error\":\"unauthorized\"}")
    end
    try
        base = "http://$(HTTP.server_addr(server))/v1"
        for code in (401, 429, 500), model in (OpenAI(base, "test", secret), OpenAIResponses(base, "test", secret)), operation in (JuliaForever.complete, JuliaForever.stream)
            status[] = code
            result = operation(model, [], Dict())
            @test !result.done
            @test result.error isa JuliaForever.ProviderStatus
            @test result.error.status == code
            @test !occursin(secret, sprint(show, result.error))
            @test !occursin(secret, JSON3.write((; failure=result.error)))
            @test !occursin(secret, JSON3.write((; provider=model)))
        end
        status[] = 302
        for model in (OpenAI(base, "test", secret), OpenAIResponses(base, "test", secret))
            @test JuliaForever.complete(model, [], Dict()).error == ProviderStatus(302)
            failure = try
                JuliaForever.stream(model, [], Dict())
            catch exception
                exception
            end
            @test failure isa ErrorException
            @test !occursin(secret, JSON3.write((; failure)))
        end
        status[] = 401
        for model in (OpenAI(base, "test", secret), OpenAIResponses(base, "test", secret))
            events = []
            result = JuliaForever.stream(model, [], Dict(); on_event=event -> push!(events, event))
            @test length(events) == 1 && only(events).type == :incomplete
            @test only(events).result == result
            @test JuliaForever.Execution.result(result, true).error == ProviderStatus(401)
        end
        login = JuliaForever.authorize()
        @test !occursin(login.verifier, JSON3.write((; login)))
        @test !occursin(login.verifier, sprint(show, login))
        @test !occursin(login.url, sprint(show, login))
        @test JuliaForever.exchange(login, "synthetic-code"; base) == ProviderStatus(401)
        callback = JuliaForever.OpenRouterCallback()
        try
            @test !occursin(callback.state, JSON3.write((; callback)))
        finally
            close(callback)
        end
    finally
        close(server)
        wait(server)
    end
end
