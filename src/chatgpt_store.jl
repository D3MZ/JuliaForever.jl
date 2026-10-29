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
        value = readprivate(file)
        value isa Rejected && return value
        occursin(r"^urn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", value) ? value : Rejected(:invalid_host)
    end
end

path(store::Store, client::AbstractString, subject::AbstractString) = joinpath(store.root, bytes2hex(sha256(JSON3.write([client, subject]))) * ".json")

function record(session::Session)
    JSON3.write((; issuer, subject=session.identity.subject, email=session.identity.email, client_id=session.client, access_token=session.access, refresh_token=session.refresh, id_token=session.id_token, scope=session.scope, expires_at=session.expires))
end

function saveunlocked(store::Store, session::Session)
    writeprivate(path(store, session.client, session.identity.subject), record(session))
    session
end

save(store::Store, session::Session) = guarded(() -> saveunlocked(store, session), store)

function loadunlocked(store::Store, client::AbstractString, subject::AbstractString)
    raw = readprivate(path(store, client, subject))
    raw isa Rejected && return raw
    data = decode(raw)
    data isa InvalidResponse && return Rejected(:invalid)
    get(data, "issuer", nothing) == issuer && get(data, "client_id", nothing) == client && get(data, "subject", nothing) == subject || return Rejected(:identity)
    access, refresh, token, scope = (get(data, key, nothing) for key in ("access_token", "refresh_token", "id_token", "scope"))
    all(value -> value isa AbstractString && !isempty(value), (access, refresh, token, scope)) || return Rejected(:invalid)
    expires = get(data, "expires_at", nothing)
    expires isa Real && !(expires isa Bool) && isfinite(expires) && expires > 0 || return Rejected(:invalid)
    email = get(data, "email", nothing)
    isnothing(email) || email isa AbstractString || return Rejected(:invalid)
    Session(String(client), Identity(String(subject), isnothing(email) ? nothing : String(email)), String(access), String(refresh), String(token), String(scope), Float64(expires))
end

load(store::Store, client::AbstractString, subject::AbstractString) = guarded(() -> loadunlocked(store, client, subject), store)

function refresh(store::Store, client::AbstractString, identity::AbstractString; post=posttoken, now=time)
    guarded(store) do
        session = loadunlocked(store, client, identity)
        session isa Rejected && return session
        session.expires > now() + 60 && return session
        fields = ["grant_type" => "refresh_token", "client_id" => session.client, "refresh_token" => session.refresh, "resource" => "https://api.openai.com/v1"]
        body = join(("$(HTTP.escapeuri(key))=$(HTTP.escapeuri(value))" for (key, value) in fields), "&")
        data = decode(post(body))
        data isa InvalidResponse && return Rejected(:response)
        access = get(data, "access_token", nothing)
        renewed = get(data, "refresh_token", nothing)
        scope = get(data, "scope", session.scope)
        kind = get(data, "token_type", nothing)
        expires = get(data, "expires_in", nothing)
        all(value -> value isa AbstractString && !isempty(value), (access, renewed, scope)) || return Rejected(:response)
        kind isa AbstractString && lowercase(kind) == "bearer" || return Rejected(:response)
        expires isa Real && !(expires isa Bool) && isfinite(expires) && expires > 0 || return Rejected(:response)
        replacement = Session(session.client, session.identity, String(access), String(renewed), session.id_token, String(scope), Float64(now() + expires))
        saveunlocked(store, replacement)
    end
end
