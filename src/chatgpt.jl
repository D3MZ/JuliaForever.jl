module ChatGPT

using HTTP, JSON3, JWTs, StructTypes
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
    fetchresult(response, get(Dict(200 => IdentitySuccess()), response.status, nothing))
end
struct IdentitySuccess end
fetchresult(response, ::Nothing) = "{}"
fetchresult(response, ::IdentitySuccess) = String(response.body)

signingkeys(raw::AbstractString) = signingkeys(decode(raw))
signingkeys(raw) = "{}"
signingkeys(data::AbstractDict) = signingkeylist(get(data, "keys", nothing))
signingkeylist(keys) = "{}"
function signingkeylist(keys::AbstractVector)
    selected = Any[]
    foreach(key -> signingkey!(selected, key), keys)
    ids = [key["kid"] for key in selected]
    length(unique(ids)) == length(ids) || return "{}"
    JSON3.write(Dict("keys" => selected))
end
signingkey!(selected, key) = nothing
function signingkey!(selected, key::AbstractDict)
    get(key, "kty", nothing) == "RSA" || return nothing
    get(key, "alg", "RS256") == "RS256" || return nothing
    get(key, "use", "sig") == "sig" || return nothing
    all(name -> !haskey(key, name), ("d", "p", "q", "dp", "dq", "qi", "oth")) || return nothing
    signingkey!(selected, key, get(key, "kid", nothing), get(key, "key_ops", nothing))
end
signingkey!(selected, key, id, operations) = nothing
signingkey!(selected, key, id::AbstractString, ::Nothing) = isempty(id) || push!(selected, key)
function signingkey!(selected, key, id::AbstractString, operations::AbstractVector)
    !isempty(id) && "verify" in operations && push!(selected, key)
    nothing
end

function validate(token::AbstractString, client::AbstractString, nonce::AbstractString; subject=nothing, fetcher=fetch, now=time)
    isempty(client) && return nothing
    client == "dynamic_agent_client" && return nothing
    isempty(nonce) && return nothing
    source = url -> signingkeys(fetcher(url))
    verifier = JWTs.Verifier(; jwks_uri=jwks, algorithms=["RS256"], issuer, audience=client, nonce, required_claims=["iss", "aud", "sub", "iat", "exp", "nonce"], leeway=5, fetcher=source, now)
    claims = JWTs.claims(JWTs.verify(verifier, String(token)))
    identitysubject(claims, client, subject, get(claims, "sub", nothing))
end
identitysubject(claims, client, subject, id) = nothing
function identitysubject(claims, client, subject, id::AbstractString)
    isempty(strip(id)) && return nothing
    identitymatch(claims, client, subject, id)
end
identitymatch(claims, client, subject, id) = nothing
identitymatch(claims, client, ::Nothing, id) = identityaudience(claims, client, id, get(claims, "aud", nothing), get(claims, "azp", nothing))
function identitymatch(claims, client, subject::AbstractString, id)
    subject == id || return nothing
    identityaudience(claims, client, id, get(claims, "aud", nothing), get(claims, "azp", nothing))
end
identityaudience(claims, client, id, audience, authorized) = nothing
identityaudience(claims, client, id, audience, ::Nothing) = identityaudience(claims, client, id, audience)
function identityaudience(claims, client, id, audience, authorized::AbstractString)
    authorized == client || return nothing
    identitytimes(claims, id, get(claims, "iat", nothing), get(claims, "exp", nothing))
end
identityaudience(claims, client, id, audience) = identitytimes(claims, id, get(claims, "iat", nothing), get(claims, "exp", nothing))
function identityaudience(claims, client, id, audience::AbstractVector)
    length(audience) > 1 && return nothing
    identitytimes(claims, id, get(claims, "iat", nothing), get(claims, "exp", nothing))
end
identitytimes(claims, id, issued, expires) = nothing
function identitytimes(claims, id, issued::Real, expires::Real)
    isfinite(issued) && isfinite(expires) || return nothing
    identityemail(id, get(claims, "email", nothing))
end
identityemail(id, email) = Identity(String(id), nothing)
identityemail(id, email::AbstractString) = Identity(String(id), String(email))

include("chatgpt_callback.jl")
include("chatgpt_exchange.jl")
include("chatgpt_plan_type.jl")
include("chatgpt_store.jl")

const Sensitive = Union{Authorization, Returning, Reconsent, Pending, Code, TokenReply, OAuthError, Session, Grant, Plan}
StructTypes.StructType(::Type{<:Sensitive}) = StructTypes.CustomStruct()
StructTypes.lower(::Sensitive) = "[redacted]"

end
