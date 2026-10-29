using JWTs, JSON3, Base64

const CG = JuliaForever.ChatGPT
const identityfixtures = joinpath(@__DIR__, "fixtures", "chatgpt")
const identitykeys = JSON3.read(read(joinpath(identityfixtures, "jwks.json"), String), Dict{String, Any})["keys"]
const identitytime = 1_800_000_000
const identityscope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"

function signedidentity(claims; key=1)
    private = JWTs.parse_keyfile(joinpath(identityfixtures, "key$key.pem"))
    jwt = JWTs.JWT(; payload=claims)
    JWTs.sign!(jwt, JWTs.JWKRSA("RS256", private), "key-$key")
    string(jwt)
end

function identityclaims(; changes=Dict{String, Any}())
    merge(Dict{String, Any}("iss" => "https://auth.openai.com", "aud" => "oaiapp_fixture", "sub" => "account-fixture", "nonce" => "nonce-fixture", "iat" => identitytime - 10, "exp" => identitytime + 60, "email" => "fixture@example.test"), changes)
end

function fixturevalidation(token; client="oaiapp_fixture", nonce="nonce-fixture", scope=identityscope, subject=nothing, keys=identitykeys)
    fetcher = url -> begin
        @test url == "https://auth.openai.com/.well-known/jwks.json"
        JSON3.write(Dict("keys" => keys))
    end
    CG.validate(token, client, nonce, scope; subject, fetcher, now=() -> identitytime)
end

@testset "ChatGPT ID token verification" begin
    good = signedidentity(identityclaims())
    verified = fixturevalidation(good)
    @test verified.subject == "account-fixture"
    @test verified.email == "fixture@example.test"
    @test !occursin(good, sprint(show, verified))
    @test_throws JWTs.JWTClaimError fixturevalidation(good; client="other-client")
    @test isnothing(fixturevalidation(good; client="dynamic_agent_client"))
    @test_throws JWTs.JWTClaimError fixturevalidation(good; nonce="wrong-nonce")
    @test isnothing(fixturevalidation(good; scope="openid chatgpt.tokens.use.direct.extra"))
    @test isnothing(fixturevalidation(good; subject="different-account"))
    @test isnothing(fixturevalidation(good; nonce=""))
    @test isnothing(fixturevalidation(good; client=""))
    @test fixturevalidation(good; subject="account-fixture").subject == "account-fixture"
    @test isnothing(fixturevalidation(signedidentity(identityclaims(; changes=Dict("sub" => "")))))
    for changes in (Dict("iss" => "https://invalid.example"), Dict("aud" => "wrong"), Dict("nonce" => "wrong"), Dict("exp" => identitytime - 6), Dict("iat" => identitytime + 6))
        @test_throws JWTs.JWTClaimError fixturevalidation(signedidentity(identityclaims(; changes)))
    end
    for claim in ("iss", "aud", "sub", "nonce", "iat", "exp")
        claims = identityclaims()
        delete!(claims, claim)
        @test_throws JWTs.JWTClaimError fixturevalidation(signedidentity(claims))
    end
    parts = split(good, '.')
    tampered = join([parts[1], parts[2], reverse(parts[3])], '.')
    @test_throws JWTs.JWTVerificationError fixturevalidation(tampered)
    forged = JWTs.JWT(; payload=identityclaims())
    JWTs.sign!(forged, JWTs.JWKSymmetric("HS256", collect(codeunits("synthetic-key"))), "key-1")
    @test_throws JWTs.JWTVerificationError fixturevalidation(string(forged))
    unsigned = JuliaForever.base64url(JSON3.write(Dict("alg" => "none", "kid" => "key-1"))) * "." * parts[2] * "."
    @test_throws JWTs.JWTVerificationError fixturevalidation(unsigned)
    multiple = identityclaims(; changes=Dict("aud" => ["oaiapp_fixture", "other-client"]))
    @test isnothing(fixturevalidation(signedidentity(multiple)))
    multiple["azp"] = "oaiapp_fixture"
    @test fixturevalidation(signedidentity(multiple)).subject == "account-fixture"
    multiple["azp"] = "other-client"
    @test isnothing(fixturevalidation(signedidentity(multiple)))
    @test_throws JWTs.JWTVerificationError fixturevalidation("not.a.valid.token")
    @test_throws JWTs.JWKSError fixturevalidation(signedidentity(identityclaims(); key=2); keys=identitykeys[1:1])
    @test fixturevalidation(signedidentity(identityclaims(); key=2); keys=identitykeys[2:2]).subject == "account-fixture"
    fetches = Ref(0)
    rotating = url -> begin
        fetches[] += 1
        JSON3.write(Dict("keys" => fetches[] == 1 ? identitykeys[1:1] : identitykeys[2:2]))
    end
    rotated = CG.validate(signedidentity(identityclaims(); key=2), "oaiapp_fixture", "nonce-fixture", identityscope; fetcher=rotating, now=() -> identitytime)
    @test rotated.subject == "account-fixture"
    @test fetches[] == 2
    @test_throws JWTs.JWKSError CG.validate(good, "oaiapp_fixture", "nonce-fixture", identityscope; fetcher=url -> "not-json", now=() -> identitytime)
    @test_throws JWTs.JWKSError CG.validate(good, "oaiapp_fixture", "nonce-fixture", identityscope; fetcher=url -> error("fixture network failure"), now=() -> identitytime)
    @test_throws JWTs.JWKSError fixturevalidation(good; keys=[merge(identitykeys[1], Dict("use" => "enc"))])
    @test_throws JWTs.JWKSError fixturevalidation(good; keys=[merge(identitykeys[1], Dict("key_ops" => ["encrypt"]))])
    @test_throws JWTs.JWKSError fixturevalidation(good; keys=[identitykeys[1], identitykeys[1]])
end
