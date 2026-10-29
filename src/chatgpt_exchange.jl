struct Session
    client::String
    identity::Identity
    access::String
    refresh::String
    id_token::String
    scope::String
    expires::Float64
end

Base.show(io::IO, ::Session) = print(io, "Session([redacted])")

subject(::Register) = nothing
subject(registration::Returning) = registration.subject
validclient(::Register, client) = !isempty(client) && client != "dynamic_agent_client"
validclient(registration::Returning, client) = client == registration.client

function posttoken(body)
    response = HTTP.post("https://auth.openai.com/api/accounts/oauth/token", ["Content-Type" => "application/x-www-form-urlencoded"], body; redirect=false, retry=false, cookies=false, request_timeout=10, read_idle_timeout=5, max_decompressed_size=1_048_576)
    response.status == 200 ? String(response.body) : "{}"
end

function exchange(pending::Pending, code::Code; post=posttoken, fetcher=fetch, now=time)
    validclient(pending.registration, code.client) || return nothing
    value = consume(code)
    isnothing(value) && return nothing
    fields = ["grant_type" => "authorization_code", "client_id" => code.client, "code" => value, "code_verifier" => pending.verifier, "redirect_uri" => pending.redirect, "resource" => "https://api.openai.com/v1"]
    body = join(("$(HTTP.escapeuri(key))=$(HTTP.escapeuri(value))" for (key, value) in fields), "&")
    data = decode(post(body))
    data isa InvalidResponse && return nothing
    access = get(data, "access_token", nothing)
    refresh = get(data, "refresh_token", nothing)
    token = get(data, "id_token", nothing)
    scope = get(data, "scope", nothing)
    kind = get(data, "token_type", nothing)
    expires = get(data, "expires_in", nothing)
    all(value -> value isa AbstractString && !isempty(value), (access, refresh, token, scope)) || return nothing
    kind isa AbstractString && lowercase(kind) == "bearer" || return nothing
    expires isa Real && !(expires isa Bool) && isfinite(expires) && expires > 0 || return nothing
    identity = validate(token, code.client, pending.nonce, scope; subject=subject(pending.registration), fetcher, now)
    isnothing(identity) && return nothing
    Session(code.client, identity, String(access), String(refresh), String(token), String(scope), Float64(now() + expires))
end
