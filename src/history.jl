module History

import Base: append!
import ..Durable as D
import ..Kernel as K
import ..Conversation as C

struct Rejected
    reason::Symbol
end

abstract type Store end

"A SQLite-backed history."
mutable struct SQLite{T} <: Store
    db::T
    lock::ReentrantLock
    status::Symbol
end

mutable struct Memory <: Store
    lock::ReentrantLock
    batches::Vector{Vector{Any}}
end

Memory() = Memory(ReentrantLock(), Vector{Any}[])

function Base.getproperty(history::Memory, name::Symbol)
    name === :batches || return getfield(history, name)
    lock(getfield(history, :lock)) do
        deepcopy(getfield(history, :batches))
    end
end

struct Journal <: Store
    store::D.Store
    id::Int
end

struct Snapshot
    revision::Int
    batches::Vector{Vector{Any}}
end

function Base.getproperty(snapshot::Snapshot, name::Symbol)
    value = getfield(snapshot, name)
    name === :batches ? deepcopy(value) : value
end

Base.IteratorSize(::Type{Snapshot}) = Base.HasLength()
Base.IteratorEltype(::Type{Snapshot}) = Base.HasEltype()
Base.eltype(::Type{Snapshot}) = Any
Base.length(snapshot::Snapshot) = sum(length, getfield(snapshot, :batches); init=0)

function Base.iterate(snapshot::Snapshot, cursor=(1, 1))
    batches = getfield(snapshot, :batches)
    batch, index = cursor
    batch > length(batches) && return nothing
    items = batches[batch]
    next = index == length(items) ? (batch + 1, 1) : (batch, index + 1)
    (deepcopy(items[index]), next)
end

value(x, seen) = Rejected(:unsupported_value)
value(x::Nothing, seen) = nothing
value(x::Union{Bool, Int}, seen) = x
value(x::String, seen) = isvalid(x) ? x : Rejected(:unsupported_value)
value(x::Float64, seen) = isfinite(x) ? x : Rejected(:unsupported_value)

function value(xs::Vector, seen)
    haskey(seen, xs) && return Rejected(:unsupported_value)
    seen[xs] = nothing
    try
        result = Any[]
        for item in xs
            saved = value(item, seen)
            saved isa Rejected && return saved
            push!(result, saved)
        end
        result
    finally
        delete!(seen, xs)
    end
end

function value(xs::Dict, seen)
    haskey(seen, xs) && return Rejected(:unsupported_value)
    seen[xs] = nothing
    try
        result = Dict{String, Any}()
        for (key, item) in xs
            key isa String && isvalid(key) || return Rejected(:unsupported_value)
            saved = value(item, seen)
            saved isa Rejected && return saved
            result[key] = saved
        end
        result
    finally
        delete!(seen, xs)
    end
end

encode(x::Union{Nothing, Bool, String}) = x
encode(x::Int) = Any[3, string(x)]
encode(x::Float64) = Any[2, string(reinterpret(UInt64, x); base=16, pad=16)]
encode(xs::Vector) = Any[0, Any[encode(x) for x in xs]]
encode(xs::Dict) = Any[1, Dict(key => encode(item) for (key, item) in xs)]

decode(x::Union{Nothing, Bool, Int, String}) = x

function decode(x::Vector)
    x[1] == 0 && return Any[decode(item) for item in x[2]]
    x[1] == 1 && return Dict{String, Any}(key => decode(item) for (key, item) in x[2])
    x[1] == 2 && return reinterpret(Float64, parse(UInt64, x[2]; base=16))
    parse(Int, x[2])
end

function snapshot(history::Memory)
    lock(history.lock) do
        batches = getfield(history, :batches)
        Snapshot(length(batches), deepcopy(batches))
    end
end

function append!(history::Memory, revision::Integer, batch::Vector)
    lock(history.lock) do
        batches = getfield(history, :batches)
        length(batches) == revision || return Rejected(:revision)
        isempty(batch) && return Rejected(:empty_batch)
        saved = value(batch, IdDict())
        saved isa Rejected && return saved
        push!(batches, saved)
        length(batches)
    end
end

function create(store::D.Store)
    result = D.commit!(store) do tx
        conversation = D.mint!(tx)
        conversation isa D.Rejected && return conversation
        created = D.put!(tx, D.Conversation(conversation, nothing))
        created isa D.Rejected && return created
        id = D.mint!(tx)
        id isa D.Rejected && return id
        created = D.put!(tx, D.Document(id, conversation, Dict("format" => "JuliaForever.History/1", "revision" => 0, "batches" => Any[])))
        created isa D.Rejected ? created : id
    end
    result isa D.Rejected ? Rejected(result.reason) : Journal(store, result)
end

content(result::D.Rejected) = Rejected(result.reason)
content(::Nothing) = Rejected(:history_missing)

function content(record::D.Document)
    data = record.value
    data isa Dict || return Rejected(:history_missing)
    get(data, "format", nothing) == "JuliaForever.History/1" || return Rejected(:history_missing)
    data
end

function snapshot(history::Journal)
    data = content(get(history.store, D.Document, history.id))
    data isa Rejected && return data
    Snapshot(data["revision"], Vector{Any}[Any[decode(item) for item in batch] for batch in data["batches"]])
end

function append!(history::Journal, revision::Integer, batch::Vector)
    result = D.commit!(history.store) do tx
        record = get(tx, D.Document, history.id)
        data = content(record)
        data isa Rejected && return data
        data["revision"] == revision || return Rejected(:revision)
        isempty(batch) && return Rejected(:empty_batch)
        saved = value(batch, IdDict())
        saved isa Rejected && return saved
        push!(data["batches"], Any[encode(item) for item in saved])
        data["revision"] += 1
        written = D.put!(tx, D.Document(record.id, record.conversation, data))
        written isa D.Rejected ? Rejected(written.reason) : data["revision"]
    end
    result isa D.Rejected ? Rejected(result.reason) : result
end

include("conversation_codec.jl")

end
