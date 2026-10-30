using Test, JuliaForever, HTTP, JSON3, Serialization, Distributed

provider_error_sse(data) = "data: $(JSON3.write(data))\n\n"

function provider_error_fixture()
    replies = Channel{Tuple{String, String}}(2)
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        content_type, body = take!(replies)
        HTTP.Response(200, ["Content-Type" => content_type], body)
    end
    (; server, replies, base="http://$(HTTP.server_addr(server))")
end

function check_provider_error(result, secret, provider, kind, status)
    @test !result.done
    @test isdefined(JuliaForever, :ProviderError) && result.error isa JuliaForever.ProviderError
    @test hasproperty(result.error, :provider) && result.error.provider == provider
    @test hasproperty(result.error, :kind) && result.error.kind == kind
    @test hasproperty(result.error, :status) && result.error.status == status
    @test !occursin(secret, sprint(show, result.error))
    @test !occursin(secret, sprint(show, result))
    @test !occursin(secret, JSON3.write(result))
    @test !occursin(secret, JSON3.write(result.error))
    bytes = IOBuffer()
    serialize(bytes, result)
    @test !occursin(secret, String(take!(bytes)))
end

@testset "OpenAI provider errors do not retain raw payloads" begin
    secret = "synthetic-provider-secret-QZ-7624"
    fixture = provider_error_fixture()
    try
        openai = OpenAI(fixture.base * "/v1", "fixture", secret)
        responses = OpenAIResponses(fixture.base * "/v1", "fixture", secret)
        cases = [
            (openai, Dict("error" => Dict("type" => "server_error", "code" => 503, "message" => secret)), :openai_compatible, :server, 503),
            (openai, Dict("error" => Dict("type" => secret, "code" => secret, "message" => secret)), :openai_compatible, :unknown, nothing),
            (responses, Dict("type" => "error", "code" => "server_error", "message" => secret), :openai_responses, :server, nothing),
            (responses, Dict("type" => "error", "code" => secret, "message" => secret), :openai_responses, :unknown, nothing),
        ]
        for (model, data, provider, kind, status) in cases
            put!(fixture.replies, ("text/event-stream", provider_error_sse(data) * "data: [DONE]\n\n"))
            events = []
            result = stream(model, [], Dict(); on_event=event -> push!(events, event))
            check_provider_error(result, secret, provider, kind, status)
            @test any(event -> event.type == :provider && occursin(secret, JSON3.write(event.data)), events)
            @test any(event -> event.type == :incomplete, events)
            @test JuliaForever.Execution.result(result, JuliaForever.Execution.ModelResult).error === result.error
            terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), [secret])
            @test JuliaForever.result!(terminal, result) == 1
            @test !occursin(secret, String(take!(terminal.diagnostics)))
        end

        data = Dict("error" => nothing, "choices" => [Dict("delta" => Dict("content" => "ignored"), "finish_reason" => "stop")])
        put!(fixture.replies, ("text/event-stream", provider_error_sse(data) * "data: [DONE]\n\n"))
        result = stream(openai, [], Dict())
        @test !result.done && result.error isa JuliaForever.ProviderError && result.error.kind == :unknown
        @test result.message["content"] === nothing

        data = Dict("error" => Dict("type" => "server_error", "code" => 503, "message" => secret))
        put!(fixture.replies, ("text/event-stream", provider_error_sse(data) * "data: [DONE]\n\n"))
        history = JuliaForever.History.Memory()
        agent = Agent(openai, []; history)
        recorded = respond!(agent, "synthetic request"; on_event=identity)
        check_provider_error(recorded, secret, :openai_compatible, :server, 503)
        @test !occursin(secret, repr(agent.events))
        @test !occursin(secret, repr(collect(JuliaForever.History.snapshot(history))))

        data = Dict("type" => "response.failed", "response" => Dict("status" => "failed", "error" => Dict("code" => "server_error", "message" => secret), "output" => []))
        put!(fixture.replies, ("text/event-stream", provider_error_sse(data)))
        failed = stream(responses, [], Dict())
        check_provider_error(failed, secret, :openai_responses, :server, nothing)
        @test failed.finish == "failed"

        incomplete = Dict("type" => "response.incomplete", "response" => Dict("status" => "incomplete", "incomplete_details" => Dict("reason" => "max_output_tokens", "detail" => secret), "output" => []))
        put!(fixture.replies, ("text/event-stream", provider_error_sse(incomplete)))
        result = stream(responses, [], Dict())
        check_provider_error(result, secret, :openai_responses, :max_output_tokens, nothing)
        @test result.finish == "incomplete"

        put!(fixture.replies, ("application/json", JSON3.write(data["response"])))
        check_provider_error(JuliaForever.complete(responses, [], Dict()), secret, :openai_responses, :server, nothing)

        unknown = Dict("choices" => [Dict("delta" => Dict(), "finish_reason" => secret)])
        put!(fixture.replies, ("text/event-stream", provider_error_sse(unknown) * "data: [DONE]\n\n"))
        events = []
        result = stream(openai, [], Dict(); on_event=event -> push!(events, event))
        @test !result.done && isnothing(result.finish)
        @test !occursin(secret, sprint(show, result)) && !occursin(secret, JSON3.write(result))
        @test !any(event -> event.type == :finish && occursin(secret, sprint(show, event)), events)

        data = Dict("choices" => [Dict("message" => Dict("role" => "assistant", "content" => nothing), "finish_reason" => secret)])
        context = "provider-error-fixture"
        @test JuliaForever.Execution.install!(context, openai, [])
        pool = JuliaForever.Execution.Executor(myid())
        try
            put!(fixture.replies, ("application/json", JSON3.write(data)))
            outcome = respond!(Agent(nothing, []), "start"; executor=pool, context)
            @test outcome isa JuliaForever.Execution.Turn
            model = only(outcome.models)
            @test isdefined(JuliaForever, :ProviderError) && model.error isa JuliaForever.ProviderError
            @test !occursin(secret, sprint(show, outcome))
            bytes = IOBuffer()
            serialize(bytes, outcome)
            @test !occursin(secret, String(take!(bytes)))
        finally
            close(pool)
            JuliaForever.Execution.uninstall!(context)
        end

        unknown = Dict("type" => "response.failed", "response" => Dict("status" => secret, "error" => Dict("message" => secret), "output" => []))
        put!(fixture.replies, ("text/event-stream", provider_error_sse(unknown)))
        result = stream(responses, [], Dict())
        @test !result.done && isnothing(result.finish)
        @test !occursin(secret, sprint(show, result)) && !occursin(secret, JSON3.write(result))
    finally
        close(fixture.server)
        wait(fixture.server)
        close(fixture.replies)
    end
end

@testset "typed provider event redaction" begin
    secret = "synthetic-provider-event-secret"
    data = Dict("type" => "error", "code" => "server_error", "message" => secret)
    event = JuliaForever.responseevent(data)
    @test event isa JuliaForever.ResponseError
    @test event.failure isa ProviderError && event.failure.kind == :server
    @test !occursin(secret, sprint(show, event))
    @test !occursin(secret, JSON3.write((; event)))
    state = JuliaForever.ResponseStream(identity)
    JuliaForever.handle!(state, event)
    @test state.failure == event.failure

    events = []
    finish = Ref{Union{Nothing, String}}(nothing)
    JuliaForever.recordfinish!(finish, event -> push!(events, event), secret)
    @test isempty(events)
    JuliaForever.recordfinish!(finish, event -> push!(events, event), "content_filter")
    @test only(events).reason == "content_filter"
end

@testset "provider error metadata is bounded" begin
    for code in (nothing, -1, 0, 399, 600, typemax(Int), true, "429")
        failure = JuliaForever.providererror(:google, Dict("code" => code, "message" => "private"))
        @test failure.status === nothing
    end
    @test JuliaForever.providererror(:google, Dict("code" => 400)).status == 400
    @test JuliaForever.providererror(:google, Dict("code" => 599)).status == 599
    @test JuliaForever.providererror(:anthropic, Dict("type" => Dict("reason" => "private"))).kind == :unknown
end
