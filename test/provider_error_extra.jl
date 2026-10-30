using Test, JuliaForever, HTTP, JSON3, Serialization, Distributed

@testset "Anthropic and Google provider errors do not retain raw payloads" begin
    secret = "synthetic-provider-secret-QZ-7624"
    fixture = provider_error_fixture()
    try
        anthropic = Anthropic(fixture.base, "fixture", secret)
        google = Google(fixture.base * "/v1beta", "gemini-3-fixture", secret)
        cases = [
            (anthropic, Dict("type" => "error", "error" => Dict("type" => "overloaded_error", "message" => secret)), :anthropic, :overloaded, nothing),
            (anthropic, Dict("type" => "error", "error" => Dict("type" => secret, "message" => secret)), :anthropic, :unknown, nothing),
            (google, Dict("error" => Dict("code" => 429, "status" => "RESOURCE_EXHAUSTED", "message" => secret)), :google, :resource_exhausted, 429),
            (google, Dict("error" => Dict("code" => secret, "status" => secret, "message" => secret)), :google, :unknown, nothing),
        ]
        for (model, data, provider, kind, status) in cases
            put!(fixture.replies, ("text/event-stream", provider_error_sse(data)))
            events = []
            result = stream(model, [], Dict(); on_event=event -> push!(events, event))
            check_provider_error(result, secret, provider, kind, status)
            @test any(event -> event.type == :provider && occursin(secret, JSON3.write(event.data)), events)
            @test any(event -> event.type == :incomplete, events)
        end

        data = Dict("error" => nothing, "candidates" => [Dict("content" => Dict("parts" => [Dict("text" => "partial")]), "finishReason" => "STOP")])
        put!(fixture.replies, ("text/event-stream", provider_error_sse(data)))
        result = stream(google, [], Dict())
        @test !result.done && result.error isa JuliaForever.ProviderError && result.error.kind == :unknown
        @test result.message["content"] == "partial"

        start = Dict("type" => "message_start", "message" => Dict("usage" => Dict()))
        delta = Dict("type" => "message_delta", "delta" => Dict("stop_reason" => secret), "usage" => Dict())
        stop = Dict("type" => "message_stop")
        put!(fixture.replies, ("text/event-stream", join(provider_error_sse.([start, delta, stop]))))
        result = stream(anthropic, [], Dict())
        @test !result.done && isnothing(result.finish)
        @test !occursin(secret, sprint(show, result)) && !occursin(secret, JSON3.write(result))

        unknown = Dict("candidates" => [Dict("finishReason" => secret)])
        put!(fixture.replies, ("text/event-stream", provider_error_sse(unknown)))
        events = []
        result = stream(google, [], Dict(); on_event=event -> push!(events, event))
        @test !result.done && isnothing(result.finish)
        @test !occursin(secret, sprint(show, result)) && !occursin(secret, JSON3.write(result))
        @test !any(event -> event.type == :finish && occursin(secret, sprint(show, event)), events)

        for reason in ("SAFETY", "LANGUAGE", "CONTINUATION")
            data = Dict("candidates" => [Dict("finishReason" => reason)])
            put!(fixture.replies, ("text/event-stream", provider_error_sse(data)))
            events = []
            stream(google, [], Dict(); on_event=event -> push!(events, event))
            @test any(event -> event.type == :finish && event.reason == reason, events)
        end

        data = Dict("error" => Dict("code" => 429, "status" => "RESOURCE_EXHAUSTED", "message" => secret))
        put!(fixture.replies, ("application/json", JSON3.write(data)))
        check_provider_error(JuliaForever.complete(google, [], Dict()), secret, :google, :resource_exhausted, 429)

        context = "provider-error-fixture"
        @test JuliaForever.Execution.install!(context, google, [])
        pool = JuliaForever.Execution.Executor(myid())
        try
            put!(fixture.replies, ("application/json", JSON3.write(data)))
            outcome = respond!(Agent(nothing, []), "start"; executor=pool, context)
            @test outcome isa JuliaForever.Execution.Turn
            model = only(outcome.models)
            @test hasproperty(model.error, :status) && model.error.status == 429
            @test !occursin(secret, sprint(show, outcome))
            bytes = IOBuffer()
            serialize(bytes, outcome)
            @test !occursin(secret, String(take!(bytes)))
        finally
            close(pool)
            JuliaForever.Execution.uninstall!(context)
        end
    finally
        close(fixture.server)
        wait(fixture.server)
        close(fixture.replies)
    end
end
