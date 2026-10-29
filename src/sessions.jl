module Sessions

using Dates, JSON3, Random

struct Rejected
    reason::Symbol
end

mutable struct Session
    file::Union{Nothing, String}
    header::Dict{String, Any}
    records::Vector{Dict{String, Any}}
    index::Dict{String, Dict{String, Any}}
    leaf::Union{Nothing, String}
    flushed::Bool
    terminated::Bool
end

timestamp() = Dates.format(Dates.now(Dates.UTC), dateformat"yyyy-mm-ddTHH:MM:SS.sss") * "Z"
id(n::Integer) = bytes2hex(rand(UInt8, n))

function Session(; cwd=pwd(), path=nothing)
    header = Dict{String, Any}("type" => "session", "version" => 3, "id" => id(16), "timestamp" => timestamp(), "cwd" => abspath(cwd))
    Session(isnothing(path) ? nothing : abspath(path), header, Dict{String, Any}[], Dict{String, Dict{String, Any}}(), nothing, false, true)
end

Session(path::AbstractString; cwd=pwd()) = Session(; cwd, path)

function Base.open(::Type{Session}, path::AbstractString)
    text = read(path, String)
    rows = Dict{String, Any}[]
    for line in eachline(IOBuffer(text))
        isempty(strip(line)) && continue
        row = try
            JSON3.read(line, Dict{String, Any})
        catch
            return Rejected(:invalid_session)
        end
        push!(rows, row)
    end
    isempty(rows) && return Rejected(:invalid_session)
    header = popfirst!(rows)
    get(header, "type", nothing) == "session" && get(header, "version", nothing) == 3 || return Rejected(:invalid_session)
    all(key -> get(header, key, nothing) isa AbstractString, ("id", "timestamp", "cwd")) || return Rejected(:invalid_session)
    index = Dict{String, Dict{String, Any}}()
    leaf = nothing
    for row in rows
        get(row, "type", nothing) isa AbstractString || return Rejected(:invalid_session)
        entryid = get(row, "id", nothing)
        entryid isa AbstractString && !haskey(index, entryid) || return Rejected(:invalid_session)
        parent = get(row, "parentId", missing)
        (isnothing(parent) || parent isa AbstractString) && get(row, "timestamp", nothing) isa AbstractString || return Rejected(:invalid_session)
        index[entryid] = row
        leaf = entryid
    end
    Session(abspath(path), header, rows, index, leaf, true, endswith(text, '\n'))
end

header(session::Session) = deepcopy(session.header)
leaf(session::Session) = session.leaf
entries(session::Session) = deepcopy(session.records)

function children(session::Session, parent::Union{Nothing, AbstractString})
    deepcopy([entry for entry in session.records if entry["parentId"] == parent])
end

function branch(session::Session, from::Union{Nothing, AbstractString}=session.leaf)
    path = Dict{String, Any}[]
    seen = Set{String}()
    while !isnothing(from) && haskey(session.index, from) && !(from in seen)
        push!(seen, from)
        entry = session.index[from]
        push!(path, entry)
        from = entry["parentId"]
    end
    reverse!(path)
    deepcopy(path)
end

messages(session::Session, from::Union{Nothing, AbstractString}=session.leaf) = [entry["message"] for entry in branch(session, from) if entry["type"] == "message"]

function branch!(session::Session, from::Union{Nothing, AbstractString})
    isnothing(from) || haskey(session.index, from) || return false
    session.leaf = from
    true
end

function persist!(session::Session, entry::Dict{String, Any})
    isnothing(session.file) && return
    if session.flushed
        bytes = (session.terminated ? "" : "\n") * JSON3.write(entry) * "\n"
        open(session.file, "a") do io
            write(io, bytes)
        end
        session.terminated = true
    elseif entry["type"] == "message" && get(entry["message"], "role", nothing) in ("user", "assistant")
        bytes = join((JSON3.write(row) * "\n" for row in (session.header, session.records..., entry)))
        io = Base.Filesystem.open(session.file, Base.JL_O_WRONLY | Base.JL_O_CREAT | Base.JL_O_EXCL, 0o666)
        try
            write(io, bytes)
        finally
            close(io)
        end
        session.flushed = true
        session.terminated = true
    end
    nothing
end

function record!(session::Session, type::AbstractString, fields::AbstractDict)
    entry = JSON3.read(JSON3.write(fields), Dict{String, Any})
    entryid = id(4)
    while haskey(session.index, entryid)
        entryid = id(4)
    end
    merge!(entry, Dict("type" => String(type), "id" => entryid, "parentId" => session.leaf, "timestamp" => timestamp()))
    persist!(session, entry)
    push!(session.records, entry)
    session.index[entryid] = entry
    session.leaf = entryid
    entryid
end

record!(session::Session, message::AbstractDict) = record!(session, "message", Dict("message" => message))

end
