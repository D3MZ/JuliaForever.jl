module ChatGPT

using HTTP, JSON3, JWTs
using ..JuliaForever: decode, InvalidResponse

const issuer = "https://auth.openai.com"
const jwks = "https://auth.openai.com/.well-known/jwks.json"
const direct = "chatgpt.tokens.use.direct"

struct Identity
    subject::String
    email::Union{Nothing, String}
end

function fetch(url)
    url == jwks || return "{}"
    response = HTTP.get(jwks; redirect=false, retry=false, cookies=false, request_timeout=10, read_idle_timeout=5, max_decompressed_size=1_048_576)
    response.status == 200 ? String(response.body) : "{}"
end

function signing(key)
    key isa AbstractDict || return false
    get(key, "kty", nothing) == "RSA" || return false
    get(key, "alg", "RS256") == "RS256" || return false
    get(key, "use", "sig") == "sig" || return false
    id = get(key, "kid", nothing)
    id isa AbstractString && !isempty(id) || return false
    operations = get(key, "key_ops", nothing)
    isnothing(operations) || (operations isa AbstractVector && "verify" in operations) || return false
    all(name -> !haskey(key, name), ("d", "p", "q", "dp", "dq", "qi", "oth"))
end

signingkeys(raw::AbstractString) = signingkeys(decode(raw))
signingkeys(::InvalidResponse) = "{}"
signingkeys(raw) = "{}"

function signingkeys(data::AbstractDict)
    keys = get(data, "keys", nothing)
    keys isa AbstractVector || return "{}"
    selected = filter(signing, keys)
    ids = [key["kid"] for key in selected]
    length(unique(ids)) == length(ids) || return "{}"
    JSON3.write(Dict("keys" => selected))
end

matches(::Nothing, id) = true
matches(subject::AbstractString, id) = subject == id

function validate(token::AbstractString, client::AbstractString, nonce::AbstractString, scope::AbstractString; subject=nothing, fetcher=fetch, now=time)
    isempty(client) && return nothing
    client == "dynamic_agent_client" && return nothing
    isempty(nonce) && return nothing
    direct in split(scope) || return nothing
    source = url -> signingkeys(fetcher(url))
    verifier = JWTs.Verifier(; jwks_uri=jwks, algorithms=["RS256"], issuer, audience=client, nonce, required_claims=["iss", "aud", "sub", "iat", "exp", "nonce"], leeway=5, fetcher=source, now)
    claims = JWTs.claims(JWTs.verify(verifier, String(token)))
    id = get(claims, "sub", nothing)
    id isa AbstractString && !isempty(strip(id)) || return nothing
    matches(subject, id) || return nothing
    audience = get(claims, "aud", nothing)
    authorized = get(claims, "azp", nothing)
    (!isnothing(authorized) && authorized != client) && return nothing
    audience isa AbstractVector && length(audience) > 1 && authorized != client && return nothing
    all(name -> get(claims, name, nothing) isa Real && isfinite(claims[name]), ("iat", "exp")) || return nothing
    email = get(claims, "email", nothing)
    Identity(String(id), email isa AbstractString ? String(email) : nothing)
end


include("chatgpt_callback.jl")
include("chatgpt_exchange.jl")
include("chatgpt_plan_type.jl")
include("chatgpt_store.jl")

end
