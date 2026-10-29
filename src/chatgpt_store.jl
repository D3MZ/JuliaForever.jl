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
    finally
        isopen(io) && close(io)
        rm(temporary; force=true)
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

save(store::Store, session::Credential) = guarded(() -> saveunlocked(store, session), store)

loadunlocked(store::Store, client::AbstractString, subject::AbstractString) = loadrecord(readprivate(path(store, client, subject)), client, subject)
loadrecord(value::Rejected, client, subject) = value
loadrecord(raw::AbstractString, client, subject) = loadrecord(decode(raw), client, subject)
loadrecord(::InvalidResponse, client, subject) = Rejected(:invalid)

function loadrecord(data::AbstractDict, client, subject)
    get(data, "issuer", nothing) == issuer && get(data, "client_id", nothing) == client && get(data, "subject", nothing) == subject || return Rejected(:identity)
    email = get(data, "email", nothing)
    isnothing(email) || email isa AbstractString || return Rejected(:invalid)
    identity = Identity(String(subject), isnothing(email) ? nothing : String(email))
    credentials(get(data, "access_token", nothing), data, client, identity)
end

function credentials(::Nothing, data, client, identity)
    all(key -> !haskey(data, key), ("access_token", "refresh_token", "id_token", "scope", "expires_at")) || return Rejected(:invalid)
    Account(String(client), identity)
end

function credentials(access::AbstractString, data, client, identity)
    token, scope = (get(data, key, nothing) for key in ("id_token", "scope"))
    all(value -> value isa AbstractString && !isempty(value), (access, token, scope)) || return Rejected(:invalid)
    expires = get(data, "expires_at", nothing)
    expires isa Real && !(expires isa Bool) && isfinite(expires) && expires > 0 || return Rejected(:invalid)
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
    access = get(data, "access_token", nothing)
    renewed = get(data, "refresh_token", nothing)
    scope = get(data, "scope", session.scope)
    kind = get(data, "token_type", nothing)
    expires = get(data, "expires_in", nothing)
    all(value -> value isa AbstractString && !isempty(value), (access, renewed, scope)) || return Rejected(:response)
    kind isa AbstractString && lowercase(kind) == "bearer" || return Rejected(:response)
    expires isa Real && !(expires isa Bool) && isfinite(expires) && expires > 0 || return Rejected(:response)
    replacement = Session(session.client, session.identity, String(access), String(renewed), session.id_token, String(scope), Float64(received + expires))
    saveunlocked(store, replacement)
end
