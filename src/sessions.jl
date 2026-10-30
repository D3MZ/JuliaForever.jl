module Sessions

using Dates, JSON3, Random
import ..Conversation as C

struct Rejected
    reason::Symbol
end

abstract type Persistence end
struct Buffered <: Persistence end
struct Persisted <: Persistence end
abstract type Ending end
struct Unterminated <: Ending end
struct Terminated <: Ending end
const persistencestates = Dict(false => Buffered(), true => Persisted())
const endingstates = Dict(false => Unterminated(), true => Terminated())
persistence(value) = persistencestates[convert(Bool, value)]
ending(value) = endingstates[convert(Bool, value)]
flushed(::Buffered) = false
flushed(::Persisted) = true
terminated(::Unterminated) = false
terminated(::Terminated) = true

JSON3.StructTypes.StructType(::Type{<:Persistence}) = JSON3.StructTypes.CustomStruct()
JSON3.StructTypes.lowertype(::Type{<:Persistence}) = Bool
JSON3.StructTypes.lower(status::Persistence) = flushed(status)
JSON3.StructTypes.construct(::Type{Persistence}, value::Bool) = persistence(value)
JSON3.StructTypes.StructType(::Type{<:Ending}) = JSON3.StructTypes.CustomStruct()
JSON3.StructTypes.lowertype(::Type{<:Ending}) = Bool
JSON3.StructTypes.lower(status::Ending) = terminated(status)
JSON3.StructTypes.construct(::Type{Ending}, value::Bool) = ending(value)

mutable struct Session
    file::Union{Nothing, String}
    header::Dict{String, Any}
    records::Vector{Dict{String, Any}}
    index::Dict{String, Dict{String, Any}}
    leaf::Union{Nothing, String}
    persistence::Persistence
    ending::Ending

    function Session(file, header, records, index, leaf, persistence::Persistence, ending::Ending)
        new(file, header, records, index, leaf, persistence, ending)
    end
end

Session(file, header, records, index, leaf, flushed, terminated) = Session(file, header, records, index, leaf, persistence(flushed), ending(terminated))
function Base.getproperty(session::Session, name::Symbol)
    name === :flushed && return flushed(getfield(session, :persistence))
    name === :terminated && return terminated(getfield(session, :ending))
    getfield(session, name)
end
function Base.setproperty!(session::Session, name::Symbol, value)
    name === :flushed && return flushed(setfield!(session, :persistence, persistence(value)))
    name === :terminated && return terminated(setfield!(session, :ending, ending(value)))
    setfield!(session, name, convert(fieldtype(Session, name), value))
end
Base.propertynames(::Session, private::Bool=false) = (:file, :header, :records, :index, :leaf, :flushed, :terminated, :persistence, :ending)
JSON3.StructTypes.names(::Type{Session}) = ((:persistence, :flushed), (:ending, :terminated))

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

const entrytypes = Dict("message" => C.Message)
const messageroles = Dict("user" => C.User, "assistant" => C.Assistant)

function messages(session::Session, from::Union{Nothing, AbstractString}=session.leaf)
    result = Any[]
    for entry in branch(session, from)
        addmessage!(result, entry, get(entrytypes, entry["type"], nothing))
    end
    result
end
addmessage!(result, entry, ::Nothing) = nothing
addmessage!(result, entry, ::Type{C.Message}) = push!(result, entry["message"])

function branch!(session::Session, from::Union{Nothing, AbstractString})
    isnothing(from) || haskey(session.index, from) || return false
    session.leaf = from
    true
end

persist!(session::Session, entry::Dict{String, Any}) = persist!(session, entry, session.file)
persist!(session::Session, entry::Dict{String, Any}, ::Nothing) = nothing
persist!(session::Session, entry::Dict{String, Any}, path::String) = persist!(session, entry, path, getfield(session, :persistence))

prefix(::Terminated) = ""
prefix(::Unterminated) = "\n"
function persist!(session::Session, entry::Dict{String, Any}, path::String, ::Persisted)
    bytes = prefix(getfield(session, :ending)) * JSON3.write(entry) * "\n"
    open(path, "a") do io
        write(io, bytes)
    end
    setfield!(session, :ending, Terminated())
    nothing
end

persist!(session::Session, entry::Dict{String, Any}, path::String, ::Buffered) = persist_entry!(session, entry, path, get(entrytypes, entry["type"], nothing))
persist_entry!(session, entry, path, ::Nothing) = nothing
persist_entry!(session, entry, path, ::Type{C.Message}) = persist_role!(session, entry, path, get(messageroles, get(entry["message"], "role", nothing), nothing))
persist_role!(session, entry, path, ::Nothing) = nothing
function persist_role!(session, entry, path, ::Type{<:C.Message})
    bytes = join((JSON3.write(row) * "\n" for row in (session.header, session.records..., entry)))
    io = Base.Filesystem.open(path, Base.JL_O_WRONLY | Base.JL_O_CREAT | Base.JL_O_EXCL, 0o666)
    try
        write(io, bytes)
    finally
        close(io)
    end
    setfield!(session, :persistence, Persisted())
    setfield!(session, :ending, Terminated())
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
