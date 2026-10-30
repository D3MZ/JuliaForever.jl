abstract type Credential end

struct Session <: Credential
    client::String
    identity::Identity
    access::String
    refresh::String
    id_token::String
    scope::String
    expires::Float64
end

struct Grant <: Credential
    client::String
    identity::Identity
    access::String
    id_token::String
    scope::String
    expires::Float64
end

Base.show(io::IO, ::Session) = print(io, "Session([redacted])")
Base.show(io::IO, ::Grant) = print(io, "Grant([redacted])")

subject(::Register) = nothing
subject(registration::Returning) = registration.subject
subject(registration::Reconsent) = subject(registration.registration)
validclient(::Register, client) = !isempty(client) && client != "dynamic_agent_client"
validclient(registration::Returning, client) = client == registration.client
validclient(registration::Reconsent, client) = validclient(registration.registration, client)

struct TokenReply
    status::Int
    body::String
end

Base.show(io::IO, reply::TokenReply) = print(io, "TokenReply(", reply.status, ", [redacted])")

struct OAuthError
    status::Int
    code::Union{Nothing, String}
end

Base.show(io::IO, failure::OAuthError) = print(io, "OAuthError(", failure.status, ", [redacted])")

function posttoken(body; request=HTTP.post)
    response = request("https://auth.openai.com/api/accounts/oauth/token", ["Content-Type" => "application/x-www-form-urlencoded"], body; status_exception=false, redirect=false, retry=false, cookies=false, request_timeout=10, read_idle_timeout=5, max_decompressed_size=1_048_576)
    TokenReply(response.status, String(response.body))
end

errorcode(::InvalidResponse) = nothing
errorcode(data::AbstractDict) = codevalue(get(data, "error", nothing))
codevalue(value::AbstractString) = String(value)
codevalue(value::AbstractDict) = codevalue(get(value, "code", nothing))
codevalue(value) = nothing

struct TokenSuccess end
tokendata(reply::TokenReply) = tokendata(reply, get(Dict(200 => TokenSuccess()), reply.status, nothing))
tokendata(reply::TokenReply, ::TokenSuccess) = decode(reply.body)
tokendata(reply::TokenReply, ::Nothing) = OAuthError(reply.status, errorcode(decode(reply.body)))

function exchange(pending::Pending, code::Code; post=posttoken, fetcher=fetch, now=time)
    validclient(pending.registration, code.client) || return nothing
    exchange(pending, code, consume(code); post, fetcher, now)
end

exchange(pending::Pending, code::Code, ::Nothing; post, fetcher, now) = nothing

function exchange(pending::Pending, code::Code, value::AbstractString; post, fetcher, now)
    fields = ["grant_type" => "authorization_code", "client_id" => code.client, "code" => value, "code_verifier" => pending.verifier, "redirect_uri" => pending.redirect, "resource" => "https://api.openai.com/v1"]
    body = join(("$(HTTP.escapeuri(key))=$(HTTP.escapeuri(value))" for (key, value) in fields), "&")
    raw = post(body)
    received = now()
    exchange(pending, code, tokendata(raw); fetcher, now, received)
end

exchange(pending::Pending, code::Code, ::InvalidResponse; fetcher, now, received) = nothing
exchange(pending::Pending, code::Code, failure::OAuthError; fetcher, now, received) = failure

function exchange(pending::Pending, code::Code, data::AbstractDict; fetcher, now, received)
    fields = (get(data, "access_token", nothing), get(data, "refresh_token", nothing), get(data, "id_token", nothing), get(data, "scope", nothing), get(data, "token_type", nothing), get(data, "expires_in", nothing))
    exchanged(pending, code, fields...; fetcher, now, received)
end
exchanged(pending, code, access, refresh, token, scope, kind, expires; fetcher, now, received) = nothing
exchanged(pending, code, access::AbstractString, refresh::Union{Nothing, AbstractString}, token::AbstractString, scope::AbstractString, kind::AbstractString, expires::Bool; fetcher, now, received) = nothing
function exchanged(pending, code, access::AbstractString, refresh::Union{Nothing, AbstractString}, token::AbstractString, scope::AbstractString, kind::AbstractString, expires::Real; fetcher, now, received)
    all(value -> !isempty(value), (access, token, scope)) || return nothing
    lowercase(kind) == "bearer" || return nothing
    isfinite(expires) && expires > 0 || return nothing
    exchangedrefresh(pending, code, access, refresh, token, scope, received + expires; fetcher, now)
end
exchangedrefresh(pending, code, access, ::Nothing, token, scope, expires; fetcher, now) = verifiedexchange(pending, code, access, nothing, token, scope, expires; fetcher, now)
function exchangedrefresh(pending, code, access, refresh::AbstractString, token, scope, expires; fetcher, now)
    isempty(refresh) && return nothing
    verifiedexchange(pending, code, access, refresh, token, scope, expires; fetcher, now)
end
function verifiedexchange(pending, code, access, refresh, token, scope, expires; fetcher, now)
    identity = validate(token, code.client, pending.nonce; subject=subject(pending.registration), fetcher, now)
    session(identity, code.client, access, refresh, token, scope, expires)
end

session(::Nothing, client, access, refresh, token, scope, expires) = nothing
session(identity::Identity, client, access, ::Nothing, token, scope, expires) = Grant(String(client), identity, String(access), String(token), String(scope), Float64(expires))
session(identity::Identity, client, access, refresh::AbstractString, token, scope, expires) = Session(String(client), identity, String(access), String(refresh), String(token), String(scope), Float64(expires))
