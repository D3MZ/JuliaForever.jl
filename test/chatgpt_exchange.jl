using HTTP, JSON3, JWTs

function fixturetokens(pending, client="oaiapp_fixture"; changes=Dict{String, Any}())
    claims = identityclaims(; changes=Dict("aud" => client, "nonce" => pending.nonce))
    merge(Dict{String, Any}("access_token" => "synthetic-access", "refresh_token" => "synthetic-refresh", "id_token" => signedidentity(claims), "scope" => identityscope, "token_type" => "Bearer", "expires_in" => 3600), changes)
end

function fixtureexchange(pending, code; changes=Dict{String, Any}(), fetcher=url -> JSON3.write(Dict("keys" => identitykeys)))
    body = Ref("")
    post = value -> begin
        body[] = value
        CG.TokenReply(200, JSON3.write(fixturetokens(pending, code.client; changes)))
    end
    session = CG.exchange(pending, code; post, fetcher, now=() -> identitytime)
    (; session, body=body[])
end

@testset "ChatGPT authorization code exchange" begin
    pending = CG.Pending(CG.Register(), "urn:uuid:host-fixture")
    try
        @test callbackget(pending, "state=$(pending.state)&code=synthetic%2Bcode&client_id=oaiapp_fixture").status == 200
        code = wait(pending; timeout=1)
        result = fixtureexchange(pending, code)
        form = HTTP.queryparams(HTTP.URI("http://127.0.0.1/?" * result.body))
        @test form == Dict("grant_type" => "authorization_code", "client_id" => "oaiapp_fixture", "code" => "synthetic+code", "code_verifier" => pending.verifier, "redirect_uri" => pending.redirect, "resource" => "https://api.openai.com/v1")
        @test result.session.identity.subject == "account-fixture"
        @test result.session.client == "oaiapp_fixture"
        @test result.session.access == "synthetic-access"
        @test result.session.refresh == "synthetic-refresh"
        @test result.session.expires == identitytime + 3600
        @test !occursin("synthetic-access", sprint(show, result.session))
        @test !occursin("synthetic-refresh", sprint(show, result.session))
        for value in (result.session, Dict("session" => result.session), [result.session], CG.TokenReply(200, "synthetic-access synthetic-refresh"))
            serialized = JSON3.write(value)
            @test !occursin("synthetic-access", serialized) && !occursin("synthetic-refresh", serialized)
            @test occursin("[redacted]", serialized)
        end
        @test isnothing(fixtureexchange(pending, code).session)
        identityonly = fixtureexchange(pending, CG.Code("synthetic-code", "oaiapp_fixture"); changes=Dict("scope" => "openid profile email")).session
        @test identityonly.identity.subject == "account-fixture"
        @test identityonly.scope == "openid profile email"
        @test !JuliaForever.stream(CG.Plan("fixture-model", identityonly; now=() -> identitytime), [], Dict()).done
        clock = Ref(identitytime)
        delayed = url -> begin
            clock[] += 90
            JSON3.write(Dict("keys" => identitykeys))
        end
        timedtoken = signedidentity(identityclaims(; changes=Dict("nonce" => pending.nonce, "exp" => identitytime + 3600)))
        post = body -> CG.TokenReply(200, JSON3.write(fixturetokens(pending; changes=Dict("id_token" => timedtoken))))
        timed = CG.exchange(pending, CG.Code("synthetic-code", "oaiapp_fixture"); post, fetcher=delayed, now=() -> clock[])
        @test timed.expires == identitytime + 3600
        duplicate = CG.Code("synthetic-code", "oaiapp_fixture")
        a = Threads.@spawn fixtureexchange(pending, duplicate).session
        b = Threads.@spawn fixtureexchange(pending, duplicate).session
        @test count(isnothing, [fetch(a), fetch(b)]) == 1
        @test isnothing(fixtureexchange(pending, CG.Code("synthetic-code", "dynamic_agent_client")).session)
        for changes in (Dict("token_type" => "Basic"), Dict("access_token" => ""), Dict("refresh_token" => ""), Dict("expires_in" => 0), Dict("expires_in" => true), Dict("id_token" => ""))
            @test isnothing(fixtureexchange(pending, CG.Code("synthetic-code", "oaiapp_fixture"); changes).session)
        end
        badnonce = signedidentity(identityclaims(; changes=Dict("nonce" => "other-nonce")))
        @test_throws JWTs.JWTClaimError fixtureexchange(pending, CG.Code("synthetic-code", "oaiapp_fixture"); changes=Dict("id_token" => badnonce))
        @test_throws JWTs.JWTVerificationError fixtureexchange(pending, CG.Code("synthetic-code", "oaiapp_fixture"); changes=Dict("id_token" => "bad.token.payload"))
        code = CG.Code("synthetic-code", "oaiapp_fixture")
        @test isnothing(CG.exchange(pending, code; post=body -> CG.TokenReply(200, "not-json"), fetcher=url -> "{}", now=() -> identitytime))
    finally
        close(pending)
    end
end

@testset "ChatGPT reauthorization identity isolation" begin
    pending = CG.Pending(CG.Returning("oaiapp_fixture", "other-account"), "urn:uuid:host-fixture")
    try
        @test isnothing(fixtureexchange(pending, CG.Code("synthetic-code", "oaiapp_fixture")).session)
        @test isnothing(fixtureexchange(pending, CG.Code("synthetic-code", "other-client")).session)
    finally
        close(pending)
    end
end

@testset "ChatGPT nonrenewable grants" begin
    pending = CG.Pending(CG.Register(), "urn:uuid:host-fixture")
    try
        tokens = fixturetokens(pending; changes=Dict("scope" => "openid profile email"))
        delete!(tokens, "refresh_token")
        post = body -> CG.TokenReply(200, JSON3.write(tokens))
        fetcher = url -> JSON3.write(Dict("keys" => identitykeys))
        grant = CG.exchange(pending, CG.Code("fixture-code", "oaiapp_fixture"); post, fetcher, now=() -> identitytime)
        @test grant isa CG.Grant
        @test grant.client == "oaiapp_fixture" && grant.identity.subject == "account-fixture"
        @test !occursin("synthetic-access", sprint(show, grant)) && !occursin(grant.id_token, sprint(show, grant))
        @test !occursin("synthetic-access", JSON3.write([grant])) && !occursin(grant.id_token, JSON3.write(Dict("grant" => grant)))
        @test !JuliaForever.stream(CG.Plan("fixture-model", grant; now=() -> identitytime), [], Dict()).done
        mktempdir() do root
            store = CG.Store(root)
            @test CG.save(store, grant) === grant
            saved = CG.load(store, grant.client, grant.identity.subject)
            @test saved isa CG.Grant && saved.identity.subject == grant.identity.subject
            @test CG.refresh(store, grant.client, grant.identity.subject; now=() -> identitytime).identity.subject == grant.identity.subject
            @test CG.refresh(store, grant.client, grant.identity.subject; now=() -> identitytime + 3590) isa CG.Rejected
        end
    finally
        close(pending)
    end
end
