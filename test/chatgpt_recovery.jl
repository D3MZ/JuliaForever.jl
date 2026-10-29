using HTTP, JSON3

@testset "ChatGPT OAuth error recovery" begin
    pending = CG.Pending(CG.Register(), "urn:uuid:fixture")
    try
        session = fixtureexchange(pending, CG.Code("fixture-code", "oaiapp_fixture")).session
        replies = Channel{Any}(16)
        seen = Channel{Any}(16)
        server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
            put!(seen, (; target=request.target, body=String(request.body)))
            take!(replies)
        end
        try
            sender = (url, headers, body; kwargs...) -> HTTP.post("http://$(HTTP.server_addr(server))/token", headers, body; kwargs...)
            post = body -> CG.posttoken(body; request=sender)
            mktempdir() do root
                store = CG.Store(root)
                for code in ("invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused")
                    CG.save(store, session)
                    put!(replies, HTTP.Response(400, ["Content-Type" => "application/json"], JSON3.write(Dict("error" => code))))
                    failure = CG.refresh(store, session.client, session.identity.subject; post, now=() -> identitytime + 3590)
                    @test failure isa CG.OAuthError && failure.status == 400 && failure.code == code
                    @test take!(seen).target == "/token"
                    account = CG.load(store, session.client, session.identity.subject)
                    @test account isa CG.Account && account.client == session.client && account.identity.subject == session.identity.subject
                    record = read(CG.path(store, session.client, session.identity.subject), String)
                    @test !occursin("synthetic-access", record) && !occursin("synthetic-refresh", record) && !occursin(session.id_token, record)
                end
                CG.save(store, session)
                for (status, code) in ((503, "invalid_grant"), (401, "invalid_client"), (400, "unknown_error"))
                    put!(replies, HTTP.Response(status, ["Content-Type" => "application/json"], JSON3.write(Dict("error" => code))))
                    failure = CG.refresh(store, session.client, session.identity.subject; post, now=() -> identitytime + 3590)
                    @test failure isa CG.OAuthError && failure.status == status && failure.code == code
                    take!(seen)
                    @test CG.load(store, session.client, session.identity.subject).refresh == "synthetic-refresh"
                end
                put!(replies, HTTP.Response(503, "not-json synthetic-secret"))
                failure = CG.refresh(store, session.client, session.identity.subject; post, now=() -> identitytime + 3590)
                @test failure isa CG.OAuthError && failure.status == 503 && isnothing(failure.code)
                @test !occursin("synthetic-secret", sprint(show, failure))
                take!(seen)
                @test CG.load(store, session.client, session.identity.subject).refresh == "synthetic-refresh"
                put!(replies, HTTP.Response(400, ["Content-Type" => "application/json"], "{\"error\":\"invalid_grant\"}"))
                attempted = CG.Code("fixture-code", "oaiapp_fixture")
                failure = CG.exchange(pending, attempted; post, fetcher=url -> "{}", now=() -> identitytime)
                @test failure isa CG.OAuthError && failure.status == 400 && failure.code == "invalid_grant"
                @test attempted.client == "oaiapp_fixture"
                @test isnothing(CG.exchange(pending, attempted; post, fetcher=url -> "{}", now=() -> identitytime))
                take!(seen)
            end
        finally
            close(server)
            wait(server)
        end
    finally
        close(pending)
    end
end
