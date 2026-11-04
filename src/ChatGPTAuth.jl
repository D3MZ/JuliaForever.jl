module ChatGPTAuth

using Base64
using Dates
using HTTP
using JSON
using JWTs
using Random
using SHA
using UUIDs

const ISSUER = "https://auth.openai.com"
const AUTHORIZE = ISSUER * "/api/accounts/authorize"
const TOKEN = ISSUER * "/api/accounts/oauth/token"
const JWKS = ISSUER * "/.well-known/jwks.json"
const RESOURCE = "https://api.openai.com/v1"
const SCOPES = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
const PLAN_SCOPE = "chatgpt.tokens.use.direct"

config_dir() = abspath(expanduser(get(ENV, "JULIAFOREVER_HOME", joinpath(@__DIR__, "..", ".juliaforever"))))

struct LoginError <: Exception
    message::String
end

mutable struct Login
    server::HTTP.Server
    callback::Channel{Any}
    result::Channel{Tuple{Symbol,String}}
    claimed::Threads.Atomic{Bool}
    cancelled::Threads.Atomic{Bool}
    task::Union{Nothing,Task}
end

function ensure_dir()
    dir = config_dir()
    mkpath(dir; mode=0o700)
    chmod(dir, 0o700)
    dir
end

function save_json(filename::String, data)
    dir = ensure_dir()
    path = joinpath(dir, filename)
    temporary, io = mktemp(dir)
    try
        write(io, JSON.json(data))
        write(io, '\n')
        close(io)
        chmod(temporary, 0o600)
        mv(temporary, path; force=true)
    finally
        isopen(io) && close(io)
        isfile(temporary) && rm(temporary; force=true)
    end
end

function read_json(filename::String)
    path = joinpath(config_dir(), filename)
    isfile(path) || return nothing
    try
        data = JSON.parsefile(path)
        data isa AbstractDict ? data : nothing
    catch
        nothing
    end
end

function saved_registration()
    data = read_json("chatgpt.json")
    data === nothing && return nothing
    all(k -> get(data, k, nothing) isa AbstractString && !isempty(data[k]),
        ("client_id", "subject", "refresh_token")) || return nothing
    data
end

function host_id()
    data = read_json("host.json")
    existing = data === nothing ? nothing : get(data, "ext_agent_host_id", nothing)
    existing isa AbstractString && startswith(existing, "urn:uuid:") && return String(existing)
    id = "urn:uuid:" * string(uuid4())
    save_json("host.json", Dict("ext_agent_host_id" => id))
    id
end

function base64url(bytes::AbstractVector{UInt8})
    replace(base64encode(bytes), '+' => '-', '/' => '_', "=" => "")
end

random_urlsafe(n::Int=32) = base64url(rand(RandomDevice(), UInt8, n))

function callback_response(req, expected::String, callback::Channel{Any}, claimed::Threads.Atomic{Bool})
    try
        req.method == "GET" || return HTTP.Response(405, "Method not allowed.")
        uri = HTTP.URI(req.target)
        uri.path == "/auth/callback" || return HTTP.Response(404, "Not found.")
        pairs = HTTP.URIs.queryparampairs(uri)
        keys = first.(pairs)
        length(keys) == length(unique(keys)) || return HTTP.Response(400, "Invalid response.")
        params = Dict(pairs)
        get(params, "state", "") == expected || return HTTP.Response(400, "Invalid sign-in state.")
        Threads.atomic_cas!(claimed, false, true) == false || return HTTP.Response(409, "Already received.")
        put!(callback, params)
        return HTTP.Response(200, ["Content-Type" => "text/plain; charset=utf-8", "Cache-Control" => "no-store"],
                             "Return to JuliaForever to see the sign-in result.")
    catch
        return HTTP.Response(400, "Invalid response.")
    end
end

function open_browser(url::String)
    command = Sys.isapple() ? ["open", url] : Sys.islinux() ? ["xdg-open", url] : String[]
    isempty(command) && throw(LoginError("Opening a browser is not supported on this platform."))
    try
        run(pipeline(Cmd(command); stdout=devnull, stderr=devnull))
    catch
        throw(LoginError("Could not open the browser. Please try again."))
    end
end

function exchange_code(client_id::String, code::String, verifier::String, redirect_uri::String)
    body = HTTP.escapeuri(["grant_type" => "authorization_code", "client_id" => client_id,
                           "code" => code, "code_verifier" => verifier,
                           "redirect_uri" => redirect_uri, "resource" => RESOURCE])
    response = try
        HTTP.post(TOKEN, ["Content-Type" => "application/x-www-form-urlencoded", "Accept" => "application/json"],
                  body; status_exception=false, redirect=false, retry=false, request_timeout=30)
    catch
        throw(LoginError("Could not reach OpenAI to finish sign-in."))
    end
    response.status == 200 || throw(LoginError("OpenAI could not finish sign-in (HTTP $(response.status))."))
    try
        data = JSON.parse(String(response.body))
        data isa AbstractDict || error("invalid response")
        data
    catch
        throw(LoginError("OpenAI returned an invalid sign-in response."))
    end
end

function complete_login(params, registration, host::String, verifier::String, nonce::String, redirect_uri::String)
    haskey(params, "error") && throw(LoginError("Sign-in was not completed in the browser."))
    code = get(params, "code", "")
    isempty(code) && throw(LoginError("OpenAI did not return an authorization code."))
    old_client = registration === nothing ? "" : String(registration["client_id"])
    returned_client = get(params, "client_id", "")
    client_id = isempty(old_client) ? returned_client : old_client
    isempty(client_id) && throw(LoginError("OpenAI did not return a client registration."))
    !isempty(old_client) && !isempty(returned_client) && returned_client != old_client &&
        throw(LoginError("OpenAI returned a different client registration."))
    tokens = exchange_code(client_id, code, verifier, redirect_uri)
    id_token = get(tokens, "id_token", nothing)
    access_token = get(tokens, "access_token", nothing)
    refresh_token = get(tokens, "refresh_token", nothing)
    all(x -> x isa AbstractString && !isempty(x), (id_token, access_token, refresh_token)) ||
        throw(LoginError("OpenAI did not return the required credentials."))
    claims = try
        check = JWTs.Verifier(; jwks_uri=JWKS, algorithms=["RS256"], issuer=ISSUER,
                              audience=client_id, nonce=nonce, leeway=5,
                              required_claims=["sub", "exp", "iat", "nonce"])
        JWTs.claims(JWTs.verify(check, String(id_token)))
    catch
        throw(LoginError("Could not verify the OpenAI account response."))
    end
    subject = get(claims, "sub", nothing)
    subject isa AbstractString && !isempty(subject) || throw(LoginError("OpenAI did not return an account identity."))
    registration === nothing || subject == registration["subject"] ||
        throw(LoginError("The signed-in account does not match the saved account."))
    scopes = split(String(get(tokens, "scope", "")))
    expiry = get(tokens, "expires_in", 0)
    expiry isa Real || (expiry = 0)
    data = Dict{String,Any}(
        "issuer" => ISSUER, "subject" => String(subject), "client_id" => client_id,
        "ext_agent_host_id" => host, "id_token" => String(id_token),
        "access_token" => String(access_token), "refresh_token" => String(refresh_token),
        "token_type" => String(get(tokens, "token_type", "Bearer")),
        "expires_in" => expiry, "scope" => join(scopes, " "),
        "saved_at" => string(Dates.now(Dates.UTC)))
    email = get(claims, "email", nothing)
    email isa AbstractString && (data["email"] = String(email))
    return data, PLAN_SCOPE in scopes
end

function start_login()
    registration = saved_registration()
    host = host_id()
    state, nonce, verifier = random_urlsafe(), random_urlsafe(), random_urlsafe(64)
    challenge = base64url(sha256(verifier))
    callback = Channel{Any}(1)
    result = Channel{Tuple{Symbol,String}}(1)
    claimed, cancelled = Threads.Atomic{Bool}(false), Threads.Atomic{Bool}(false)
    server = HTTP.serve!(req -> callback_response(req, state, callback, claimed), "127.0.0.1", 0;
                         listenany=true, allow_h2c=false, read_timeout=10, max_header_bytes=16384)
    redirect_uri = "http://127.0.0.1:$(HTTP.port(server))/auth/callback"
    initial = registration === nothing
    params = ["client_id" => (initial ? "dynamic_agent_client" : String(registration["client_id"])),
              "ext_agent_host_id" => host, "response_type" => "code", "redirect_uri" => redirect_uri,
              "scope" => SCOPES, "resource" => RESOURCE, "state" => state, "nonce" => nonce,
              "code_challenge_method" => "S256", "code_challenge" => challenge]
    initial && push!(params, "agent_name_hint" => "JuliaForever")
    !initial && !(PLAN_SCOPE in split(String(get(registration, "scope", "")))) && push!(params, "prompt" => "consent")
    url = AUTHORIZE * "?" * HTTP.escapeuri(params)
    flow = Login(server, callback, result, claimed, cancelled, nothing)
    flow.task = @async begin
        try
            open_browser(url)
            response = take!(callback)
            cancelled[] && return
            data, plan_enabled = complete_login(response, registration, host, verifier, nonce, redirect_uri)
            cancelled[] && return
            save_json("chatgpt.json", data)
            put!(result, plan_enabled ? (:ready, "ChatGPT plan access is connected.") :
                                       (:limited, "Signed in; ChatGPT plan access was not granted."))
        catch e
            if !cancelled[]
                message = e isa LoginError ? e.message : "Could not complete sign-in. Please try again."
                put!(result, (:error, message))
            end
        finally
            try HTTP.forceclose(server) catch end
        end
    end
    flow
end

function cancel!(flow::Login)
    flow.cancelled[] = true
    if Threads.atomic_cas!(flow.claimed, false, true) == false
        put!(flow.callback, nothing)
    end
    try HTTP.forceclose(flow.server) catch end
end

end
