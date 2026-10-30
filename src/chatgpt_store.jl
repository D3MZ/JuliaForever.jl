using UUIDs

struct Busy end

struct Rejected
    reason::Symbol
end

struct Store
    root::String
    function Store(root::AbstractString)
        Sys.isunix() || return Rejected(:unsupported)
        directory = abspath(root)
        islink(directory) && return Rejected(:unsafe_path)
        mkpath(directory; mode=0o700)
        stat(directory).uid == ccall(:geteuid, Cuint, ()) || return Rejected(:owner)
        chmod(directory, 0o700)
        new(directory)
    end
end

function guarded(f, store::Store)
    file = Base.Filesystem.open(joinpath(store.root, "lock"), Base.Filesystem.JL_O_CREAT | Base.Filesystem.JL_O_RDWR | Base.Filesystem.JL_O_NOFOLLOW, 0o600)
    try
        info = stat(file)
        isfile(info) && info.uid == ccall(:geteuid, Cuint, ()) && info.mode & 0o077 == 0 || return Rejected(:permissions)
        if ccall(:flock, Cint, (Cint, Cint), Base.fd(file), 6) != 0
            code = Base.Libc.errno()
            code == Base.Libc.EAGAIN && return Busy()
            Base.systemerror("flock", code)
        end
        f()
    finally
        close(file)
    end
end

function writeprivate(path, value)
    temporary, io = mktemp(dirname(path))
    try
        write(io, value)
        flush(io)
        Base.systemerror("fsync", ccall(:fsync, Cint, (Cint,), Base.fd(io)) != 0)
        close(io)
        chmod(temporary, 0o600)
        Base.Filesystem.rename(temporary, path)
        syncdirectory(path)
    finally
        close(io)
        rm(temporary; force=true)
    end
    nothing
end

function syncdirectory(path)
    descriptor = ccall(:open, Cint, (Cstring, Cint), dirname(path), 0)
    Base.systemerror("open directory", descriptor < 0)
    try
        Base.systemerror("fsync directory", ccall(:fsync, Cint, (Cint,), descriptor) != 0)
    finally
        ccall(:close, Cint, (Cint,), descriptor)
    end
    nothing
end

function readprivate(path)
    isfile(path) || return Rejected(:missing)
    islink(path) && return Rejected(:unsafe_path)
    file = Base.Filesystem.open(path, Base.Filesystem.JL_O_RDONLY | Base.Filesystem.JL_O_NOFOLLOW)
    try
        info = stat(file)
        info.uid == ccall(:geteuid, Cuint, ()) && info.mode & 0o077 == 0 || return Rejected(:permissions)
        read(file, String)
    finally
        close(file)
    end
end

function host(store::Store)
    guarded(store) do
        file = joinpath(store.root, "host")
        if !ispath(file)
            value = "urn:uuid:$(uuid4(RandomDevice()))"
            writeprivate(file, value)
            return value
        end
        hostvalue(readprivate(file))
    end
end

hostvalue(value::Rejected) = value
hostvalue(value::AbstractString) = occursin(r"^urn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", value) ? value : Rejected(:invalid_host)

path(store::Store, client::AbstractString, subject::AbstractString) = joinpath(store.root, bytes2hex(sha256(JSON3.write([client, subject]))) * ".json")

struct Account
    client::String
    identity::Identity
end

function record(account::Account)
    JSON3.write((; issuer, subject=account.identity.subject, email=account.identity.email, client_id=account.client))
end

function record(grant::Grant)
    JSON3.write((; issuer, subject=grant.identity.subject, email=grant.identity.email, client_id=grant.client, access_token=grant.access, id_token=grant.id_token, scope=grant.scope, expires_at=grant.expires))
end

function record(session::Session)
    JSON3.write((; issuer, subject=session.identity.subject, email=session.identity.email, client_id=session.client, access_token=session.access, refresh_token=session.refresh, id_token=session.id_token, scope=session.scope, expires_at=session.expires))
end

function saveunlocked(store::Store, session::Union{Credential, Account})
    writeprivate(path(store, session.client, session.identity.subject), record(session))
    session
end

function save(store::Store, session::Credential)
    guarded(store) do
        file = path(store, session.client, session.identity.subject)
        (ispath(file) || islink(file)) && return Rejected(:exists)
        saveunlocked(store, session)
    end
end

function Base.replace(store::Store, expected::Union{Credential, Account}, next::Credential)
    (expected.client, expected.identity.subject) == (next.client, next.identity.subject) || return Rejected(:identity)
    guarded(store) do
        replaceunlocked(store, expected, next, loadunlocked(store, expected.client, expected.identity.subject))
    end
end

replaceunlocked(store::Store, expected, next, actual::Rejected) = actual
function replaceunlocked(store::Store, expected, next, actual::Union{Credential, Account})
    record(actual) == record(expected) || return Rejected(:changed)
    saveunlocked(store, next)
end

loadunlocked(store::Store, client::AbstractString, subject::AbstractString) = loadrecord(readprivate(path(store, client, subject)), client, subject)
loadrecord(value::Rejected, client, subject) = value
loadrecord(raw::AbstractString, client, subject) = loadrecord(decode(raw), client, subject)
loadrecord(::InvalidResponse, client, subject) = Rejected(:invalid)

function loadrecord(data::AbstractDict, client, subject)
    get(data, "issuer", nothing) == issuer && get(data, "client_id", nothing) == client && get(data, "subject", nothing) == subject || return Rejected(:identity)
    loademail(data, client, subject, get(data, "email", nothing))
end
loademail(data, client, subject, email) = Rejected(:invalid)
loademail(data, client, subject, ::Nothing) = credentials(get(data, "access_token", nothing), data, client, Identity(String(subject), nothing))
loademail(data, client, subject, email::AbstractString) = credentials(get(data, "access_token", nothing), data, client, Identity(String(subject), String(email)))

function credentials(::Nothing, data, client, identity)
    all(key -> !haskey(data, key), ("access_token", "refresh_token", "id_token", "scope", "expires_at")) || return Rejected(:invalid)
    Account(String(client), identity)
end
function credentials(access::AbstractString, data, client, identity)
    storedfields(data, client, identity, access, get(data, "id_token", nothing), get(data, "scope", nothing), get(data, "expires_at", nothing))
end
storedfields(data, client, identity, access, token, scope, expires) = Rejected(:invalid)
storedfields(data, client, identity, access, token::AbstractString, scope::AbstractString, expires::Bool) = Rejected(:invalid)
function storedfields(data, client, identity, access, token::AbstractString, scope::AbstractString, expires::Real)
    all(value -> !isempty(value), (access, token, scope)) || return Rejected(:invalid)
    isfinite(expires) && expires > 0 || return Rejected(:invalid)
    stored(get(data, "refresh_token", nothing), client, identity, access, token, scope, expires)
end

stored(::Nothing, client, identity, access, token, scope, expires) = Grant(String(client), identity, String(access), String(token), String(scope), Float64(expires))
function stored(refresh::AbstractString, client, identity, access, token, scope, expires)
    isempty(refresh) && return Rejected(:invalid)
    Session(String(client), identity, String(access), String(refresh), String(token), String(scope), Float64(expires))
end
stored(refresh, client, identity, access, token, scope, expires) = Rejected(:invalid)

credentials(access, data, client, identity) = Rejected(:invalid)

load(store::Store, client::AbstractString, subject::AbstractString) = guarded(() -> loadunlocked(store, client, subject), store)

function refresh(store::Store, client::AbstractString, identity::AbstractString; post=posttoken, now=time)
    guarded(store) do
        renew(store, loadunlocked(store, client, identity); post, now)
    end
end

renew(store::Store, rejected::Rejected; post, now) = rejected
renew(store::Store, account::Account; post, now) = Rejected(:reauthorize)
renew(store::Store, grant::Grant; post, now) = grant.expires > now() + 60 ? grant : Rejected(:reauthorize)

function renew(store::Store, session::Session; post, now)
    session.expires > now() + 60 && return session
    fields = ["grant_type" => "refresh_token", "client_id" => session.client, "refresh_token" => session.refresh, "resource" => "https://api.openai.com/v1"]
    body = join(("$(HTTP.escapeuri(key))=$(HTTP.escapeuri(value))" for (key, value) in fields), "&")
    raw = post(body)
    received = now()
    renew(store, session, tokendata(raw); received)
end

renew(store::Store, session::Session, ::InvalidResponse; received) = Rejected(:response)

function renew(store::Store, session::Session, failure::OAuthError; received)
    unusable = ("invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused")
    if 400 <= failure.status < 500 && failure.code in unusable
        saveunlocked(store, Account(session.client, session.identity))
    end
    failure
end

function renew(store::Store, session::Session, data::AbstractDict; received)
    fields = (get(data, "access_token", nothing), get(data, "refresh_token", nothing), get(data, "scope", session.scope), get(data, "token_type", nothing), get(data, "expires_in", nothing))
    renewed(store, session, fields...; received)
end
renewed(store, session, access, refresh, scope, kind, expires; received) = Rejected(:response)
renewed(store, session, access::AbstractString, refresh::AbstractString, scope::AbstractString, kind::AbstractString, expires::Bool; received) = Rejected(:response)
function renewed(store, session, access::AbstractString, refresh::AbstractString, scope::AbstractString, kind::AbstractString, expires::Real; received)
    all(value -> !isempty(value), (access, refresh, scope)) || return Rejected(:response)
    lowercase(kind) == "bearer" || return Rejected(:response)
    isfinite(expires) && expires > 0 || return Rejected(:response)
    replacement = Session(session.client, session.identity, String(access), String(refresh), session.id_token, String(scope), Float64(received + expires))
    saveunlocked(store, replacement)
end

function accounts(store::Store)
    guarded(store) do
        files = filter(file -> endswith(file, ".json"), sort(readdir(store.root; join=true)))
        foldl((records, file) -> accountfile(store, records, file), files; init=Union{Account, Credential}[])
    end
end
accountfile(store, rejected::Rejected, file) = rejected
accountfile(store, records::AbstractVector, file) = accountfile(store, records, file, readprivate(file))
accountfile(store, records, file, rejected::Rejected) = rejected
accountfile(store, records, file, raw::AbstractString) = accountdata(store, records, file, decode(raw))
accountdata(store, records, file, data) = Rejected(:invalid)
accountdata(store, records, file, data::AbstractDict) = accountdata(store, records, file, data, get(data, "client_id", nothing), get(data, "subject", nothing))
accountdata(store, records, file, data, client, subject) = Rejected(:invalid)
function accountdata(store, records, file, data, client::AbstractString, subject::AbstractString)
    file == path(store, client, subject) || return Rejected(:identity)
    accountrecord(records, loadrecord(data, client, subject))
end
accountrecord(records, rejected::Rejected) = rejected
accountrecord(records, account::Union{Account, Credential}) = push!(records, account)

struct Revoked end
struct RevocationUnconfirmed end

function revocation(session::Session; request=HTTP.request)
    try
        discovery = request("GET", "https://auth.openai.com/.well-known/openid-configuration"; status_exception=false, redirect=false, retry=false, cookies=false, request_timeout=10, read_idle_timeout=5, max_decompressed_size=1_048_576)
        revocation(session, discovery, request)
    catch
        RevocationUnconfirmed()
    end
end
revocation(session::Session, discovery, request) = revocation(session, discovery, request, get(Dict(200 => TokenSuccess()), discovery.status, nothing))
revocation(session::Session, discovery, request, ::Nothing) = RevocationUnconfirmed()
revocation(session::Session, discovery, request, ::TokenSuccess) = revocationendpoint(session, decode(String(discovery.body)), request)
revocationendpoint(session, data, request) = RevocationUnconfirmed()
revocationendpoint(session, data::AbstractDict, request) = revocationendpoint(session, get(data, "revocation_endpoint", nothing), request)
revocationendpoint(session, endpoint::Nothing, request) = RevocationUnconfirmed()
function revocationendpoint(session, endpoint::AbstractString, request)
    uri = HTTP.URI(endpoint)
    uri.scheme == "https" && uri.host == "auth.openai.com" && isempty(uri.userinfo) && isempty(uri.port) && isempty(uri.fragment) || return RevocationUnconfirmed()
    fields = ["token" => session.refresh, "token_type_hint" => "refresh_token", "client_id" => session.client]
    body = join(("$(HTTP.escapeuri(key))=$(HTTP.escapeuri(value))" for (key, value) in fields), "&")
    response = request("POST", String(endpoint), ["Content-Type" => "application/x-www-form-urlencoded"], body; status_exception=false, redirect=false, retry=false, cookies=false, request_timeout=10, read_idle_timeout=5, max_decompressed_size=1_048_576)
    revoked(response.status)
end
revoked(status) = get(Dict(200 => Revoked()), status, RevocationUnconfirmed())
revocation(::Grant; request=HTTP.request) = RevocationUnconfirmed()

function signout(store::Store, expected::Credential; request=HTTP.request)
    guarded(store) do
        signout(store, expected, loadunlocked(store, expected.client, expected.identity.subject); request)
    end
end
signout(store, expected, failure::Rejected; request) = failure
function signout(store, expected, actual::Credential; request)
    record(actual) == record(expected) || return Rejected(:changed)
    result = revocation(actual; request)
    saveunlocked(store, Account(actual.client, actual.identity))
    result
end
signout(store, expected, actual::Account; request) = Rejected(:changed)
