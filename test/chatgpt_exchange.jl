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
