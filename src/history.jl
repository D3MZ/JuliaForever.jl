module History

import Base: append!
import ..Durable as D
import ..Kernel as K
import ..Conversation as C
import ..JuliaForever: ToolResult, ToolLoaded, loaded

struct Rejected
    reason::Symbol
end

abstract type Store end

abstract type SQLiteStatus end
struct Open <: SQLiteStatus end
struct Closed <: SQLiteStatus end
struct Uncertain <: SQLiteStatus end

status(::Open) = :open
status(::Closed) = :closed
status(::Uncertain) = :uncertain

"A SQLite-backed history."
mutable struct SQLite{T} <: Store
    db::T
    lock::ReentrantLock
    status::SQLiteStatus
end

function Base.getproperty(history::SQLite, name::Symbol)
    name === :status && return status(getfield(history, :status))
    getfield(history, name)
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

consistent(::Store, snapshot::Snapshot) = length(snapshot.batches) == snapshot.revision

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
        save!(batches, value(batch, IdDict()))
    end
end

save!(batches::Vector, rejected::Rejected) = rejected

function save!(batches::Vector, saved::Vector)
    push!(batches, saved)
    length(batches)
end

function create(store::D.Store)
    result = D.commit!(create, store)
    Journal(store, result)
end

create(tx::D.Transaction) = create(tx, D.mint!(tx))
create(tx::D.Transaction, rejected::D.Rejected) = rejected
create(tx::D.Transaction, conversation::Integer) = create!(tx, conversation, D.put!(tx, D.Conversation(conversation, nothing)))
create!(tx::D.Transaction, conversation::Integer, rejected::D.Rejected) = rejected
create!(tx::D.Transaction, conversation::Integer, ::Integer) = document!(tx, conversation, D.mint!(tx))
document!(tx::D.Transaction, conversation::Integer, rejected::D.Rejected) = rejected
document!(tx::D.Transaction, conversation::Integer, id::Integer) = D.put!(tx, D.Document(id, conversation, Dict("format" => "JuliaForever.History/1", "revision" => 0, "batches" => Any[])))

Journal(store::D.Store, result::D.Rejected) = Rejected(result.reason)

content(result::D.Rejected) = Rejected(result.reason)
content(::Nothing) = Rejected(:history_missing)
content(value) = Rejected(:history_missing)
content(record::D.Document) = content(record.value)

function content(data::Dict)
    get(data, "format", nothing) == "JuliaForever.History/1" || return Rejected(:history_missing)
    data
end

snapshot(history::Journal) = snapshot(content(get(history.store, D.Document, history.id)))
snapshot(rejected::Rejected) = rejected

function snapshot(data::Dict)
    Snapshot(data["revision"], Vector{Any}[Any[decode(item) for item in batch] for batch in data["batches"]])
end

outcome(result::D.Rejected) = Rejected(result.reason)
outcome(result) = result
outcome(result::D.Rejected, value) = Rejected(result.reason)
outcome(result, value) = value

function append!(history::Journal, revision::Integer, batch::Vector)
    result = D.commit!(history.store) do tx
        record = get(tx, D.Document, history.id)
        append!(tx, record, revision, batch, content(record))
    end
    outcome(result)
end

append!(tx::D.Transaction, record, revision, batch, rejected::Rejected) = rejected

function append!(tx::D.Transaction, record, revision, batch, data::Dict)
    data["revision"] == revision || return Rejected(:revision)
    isempty(batch) && return Rejected(:empty_batch)
    append!(tx, record, data, value(batch, IdDict()))
end

append!(tx::D.Transaction, record, data::Dict, rejected::Rejected) = rejected

function append!(tx::D.Transaction, record, data::Dict, saved::Vector)
    push!(data["batches"], Any[encode(item) for item in saved])
    data["revision"] += 1
    written = D.put!(tx, D.Document(record.id, record.conversation, data))
    outcome(written, data["revision"])
end

include("conversation_codec.jl")
include("tree_history.jl")

end
