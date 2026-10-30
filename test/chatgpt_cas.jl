using JSON3

@testset "ChatGPT session compare-and-swap" begin
    pending = CG.Pending(CG.Register(), "urn:uuid:fixture")
    try
        session = fixtureexchange(pending, CG.Code("fixture-code", "oaiapp_fixture")).session
        mktempdir() do root
            store = CG.Store(root)
            @test CG.save(store, session) === session
            @test CG.save(store, session) isa CG.Rejected
            rotatedpost = body -> CG.TokenReply(200, JSON3.write(Dict("access_token" => "rotated-access", "refresh_token" => "rotated-refresh", "scope" => identityscope, "token_type" => "Bearer", "expires_in" => 3600)))
            rotated = CG.refresh(store, session.client, session.identity.subject; post=rotatedpost, now=() -> identitytime + 3590)
            stale = CG.Session(session.client, session.identity, "stale-access", "stale-refresh", session.id_token, session.scope, identitytime + 5000)
            @test CG.replace(store, session, stale) isa CG.Rejected
            @test CG.load(store, session.client, session.identity.subject).refresh == "rotated-refresh"
            reauthorized = CG.Session(session.client, session.identity, "reauth-access", "reauth-refresh", session.id_token, session.scope, identitytime + 7000)
            @test CG.replace(store, rotated, reauthorized) === reauthorized
            @test CG.load(store, session.client, session.identity.subject).refresh == "reauth-refresh"
            wrong = CG.Session("other-client", session.identity, "access", "refresh", session.id_token, session.scope, identitytime + 7000)
            @test CG.replace(store, reauthorized, wrong) isa CG.Rejected
        end
    finally
        close(pending)
    end
end

@testset "ChatGPT rotated-response crash recovery" begin
    pending = CG.Pending(CG.Register(), "urn:uuid:fixture")
    try
        session = fixtureexchange(pending, CG.Code("fixture-code", "oaiapp_fixture")).session
        mktempdir() do root
            store = CG.Store(root)
            @test CG.save(store, session) === session
            received = joinpath(root, "received")
            project = dirname(@__DIR__)
            script = """
                using JuliaForever, JSON3
                C = JuliaForever.ChatGPT
                store = C.Store(ARGS[1])
                count = Ref(0)
                now = () -> begin
                    count[] += 1
                    if count[] == 2
                        touch(ARGS[2])
                        ccall(:kill, Cint, (Cint, Cint), getpid(), 9)
                    end
                    1800003590
                end
                post = body -> C.TokenReply(200, JSON3.write(Dict("access_token" => "new-access", "refresh_token" => "new-refresh", "scope" => "openid chatgpt.tokens.use.direct", "token_type" => "Bearer", "expires_in" => 3600)))
                C.refresh(store, "oaiapp_fixture", "account-fixture"; post, now)
            """
            process = run(pipeline(`$(Base.julia_cmd()) --startup-file=no --project=$project -e $script $root $received`; stdout=devnull, stderr=devnull); wait=false)
            wait(process)
            @test !success(process) && isfile(received)
            @test CG.load(store, session.client, session.identity.subject).refresh == "synthetic-refresh"
            failure = CG.refresh(store, session.client, session.identity.subject; post=body -> CG.TokenReply(400, "{\"error\":\"invalid_grant\"}"), now=() -> identitytime + 3590)
            @test failure isa CG.OAuthError && failure.code == "invalid_grant"
            account = CG.load(store, session.client, session.identity.subject)
            @test account isa CG.Account && account.client == session.client
            replacement = CG.Session(session.client, session.identity, "reauth-access", "reauth-refresh", session.id_token, session.scope, identitytime + 7000)
            @test CG.replace(store, account, replacement) === replacement
            @test CG.load(store, session.client, session.identity.subject).refresh == "reauth-refresh"
        end
    finally
        close(pending)
    end
end
