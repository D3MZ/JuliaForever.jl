using HTTP, JSON3, JWTs

function fixturetokens(pending, client="oaiapp_fixture"; changes=Dict{String, Any}())
    claims = identityclaims(; changes=Dict("aud" => client, "nonce" => pending.nonce))
    merge(Dict{String, Any}("access_token" => "synthetic-access", "refresh_token" => "synthetic-refresh", "id_token" => signedidentity(claims), "scope" => identityscope, "token_type" => "Bearer", "expires_in" => 3600), changes)
end

function fixtureexchange(pending, code; changes=Dict{String, Any}(), fetcher=url -> JSON3.write(Dict("keys" => identitykeys)))
    body = Ref("")
    post = value -> begin
        body[] = value
        JSON3.write(fixturetokens(pending, code.client; changes))
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
        @test isnothing(fixtureexchange(pending, code).session)
        duplicate = CG.Code("synthetic-code", "oaiapp_fixture")
        a = Threads.@spawn fixtureexchange(pending, duplicate).session
        b = Threads.@spawn fixtureexchange(pending, duplicate).session
        @test count(isnothing, [fetch(a), fetch(b)]) == 1
        @test isnothing(fixtureexchange(pending, CG.Code("synthetic-code", "dynamic_agent_client")).session)
        for changes in (Dict("scope" => "openid profile"), Dict("token_type" => "Basic"), Dict("access_token" => ""), Dict("refresh_token" => ""), Dict("expires_in" => 0), Dict("expires_in" => true), Dict("id_token" => ""))
            @test isnothing(fixtureexchange(pending, CG.Code("synthetic-code", "oaiapp_fixture"); changes).session)
        end
        badnonce = signedidentity(identityclaims(; changes=Dict("nonce" => "other-nonce")))
        @test_throws JWTs.JWTClaimError fixtureexchange(pending, CG.Code("synthetic-code", "oaiapp_fixture"); changes=Dict("id_token" => badnonce))
        @test_throws JWTs.JWTVerificationError fixtureexchange(pending, CG.Code("synthetic-code", "oaiapp_fixture"); changes=Dict("id_token" => "bad.token.payload"))
        code = CG.Code("synthetic-code", "oaiapp_fixture")
        @test isnothing(CG.exchange(pending, code; post=body -> "not-json", fetcher=url -> "{}", now=() -> identitytime))
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
