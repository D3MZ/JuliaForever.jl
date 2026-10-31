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

function fixturevalidation(token; client="oaiapp_fixture", nonce="nonce-fixture", subject=nothing, keys=identitykeys)
    fetcher = url -> begin
        @test url == "https://auth.openai.com/.well-known/jwks.json"
        JSON3.write(Dict("keys" => keys))
    end
    CG.validate(token, client, nonce; subject, fetcher, now=() -> identitytime)
end
