module Durable

using JSON3

struct Rejected
    reason::Symbol
end

abstract type Record end

struct Conversation <: Record
    id::Int
    value::Any
end

struct Entry <: Record
    id::Int
    conversation::Int
    kind::String
    value::Any
end

struct Task <: Record
    id::Int
    conversation::Int
    state::Any
end

struct Document <: Record
    id::Int
    conversation::Int
    value::Any
end

struct Submission <: Record
    id::Int
    conversation::Int
    request::Union{Nothing, String}
    kind::String
    status::String
    value::Any
end

mutable struct State
    seq::Int
    nextid::Int
    records::Dict{Int, Record}
    requests::Dict{Tuple{Int, String}, Int}
end

State() = State(0, 0, Dict{Int, Record}(), Dict{Tuple{Int, String}, Int}())

mutable struct Store
    io::IOStream
    state::State
    nextid::Int
    lock::ReentrantLock
    failed::Bool
    closed::Bool
    busy::Bool
end

mutable struct Transaction
    store::Store
    state::State
    writes::Vector{Record}
    minted::Set{Int}
    owner::Core.Task
    active::Bool
    failure::Union{Nothing, Rejected}
end

encode(r::Conversation) = (; type="conversation", r.id, r.value)
encode(r::Entry) = (; type="entry", r.id, r.conversation, r.kind, r.value)
encode(r::Task) = (; type="task", r.id, r.conversation, r.state)
encode(r::Document) = (; type="document", r.id, r.conversation, r.value)
encode(r::Submission) = (; type="submission", r.id, r.conversation, r.request, r.kind, r.status, r.value)

const recordtypes = Dict("conversation" => Conversation, "entry" => Entry, "task" => Task, "document" => Document, "submission" => Submission)

decode(record::AbstractDict) = decode(get(recordtypes, record["type"], nothing), record, record["id"])
decode(::Nothing, record, id) = nothing
decode(::Type{<:Record}, record, id) = nothing
decode(::Type{Conversation}, record, id::Int) = Conversation(id, record["value"])
decode(type::Type{<:Record}, record, id::Int) = decode(type, record, id, record["conversation"])
decode(::Type{<:Record}, record, id::Int, conversation) = nothing
decode(::Type{Entry}, record, id::Int, conversation::Int) = Entry(id, conversation, record["kind"], record["value"])
decode(::Type{Task}, record, id::Int, conversation::Int) = Task(id, conversation, record["state"])
decode(::Type{Document}, record, id::Int, conversation::Int) = Document(id, conversation, record["value"])
decode(::Type{Submission}, record, id::Int, conversation::Int) = Submission(id, conversation, record["request"], record["kind"], record["status"], record["value"])

detach(record::Record) = decode(JSON3.read(JSON3.write(encode(record)), Dict{String, Any}))

validate(::Conversation) = nothing
validate(parent) = Rejected(:conversation_missing)
validate(state::State, ::Nothing, ::Conversation) = nothing
validate(state::State, ::Nothing, record::Record) = validate(get(state.records, record.conversation, nothing))
validate(state::State, existing::Record, record::Record) = validate(existing, record)
validate(existing::Record, record::Record) = Rejected(:id_in_use)
validate(existing::T, record::T) where {T <: Union{Conversation, Entry}} = Rejected(:immutable)
validate(existing::T, record::T) where {T <: Record} = existing.conversation == record.conversation ? nothing : Rejected(:immutable)
validate(existing::Submission, record::Submission) = existing.conversation == record.conversation && (existing.request, existing.kind) == (record.request, record.kind) ? nothing : Rejected(:immutable)

register!(state::State, record::Record) = nothing
register!(state::State, record::Submission) = register!(state, record, record.request)
register!(state::State, record::Submission, ::Nothing) = nothing

function register!(state::State, record::Submission, request::String)
    key = (record.conversation, request)
    get(state.requests, key, record.id) == record.id || return Rejected(:request_in_use)
    state.requests[key] = record.id
    nothing
end

function apply!(state::State, record::Record)
    record.id > 0 || return Rejected(:invalid_id)
    apply!(state, record, validate(state, get(state.records, record.id, nothing), record))
end

apply!(state::State, record::Record, rejected::Rejected) = rejected
apply!(state::State, record::Record, ::Nothing) = store!(state, record, register!(state, record))
store!(state::State, record::Record, rejected::Rejected) = rejected

function store!(state::State, record::Record, ::Nothing)
    state.records[record.id] = record
    nothing
end

function replay!(state::State, batch)
    try
        seq = batch["seq"]
        seq isa Int && seq == state.seq + 1 || return false
        nextid = batch["nextid"]
        nextid isa Int && nextid >= state.nextid || return false
        writes = batch["writes"]
        writes isa AbstractVector && !isempty(writes) || return false
        for record in writes
            record = decode(record)
            record isa Record || return false
            record.id <= nextid || return false
            apply!(state, record) === nothing || return false
        end
        state.seq += 1
        state.nextid = nextid
        true
    catch
        false
    end
end

function sync(io::IOStream)
    flush(io)
    @static if Sys.iswindows()
        Base.systemerror("_commit", ccall(:_commit, Cint, (Cint,), fd(io)) != 0)
    else
        Base.systemerror("fsync", ccall(:fsync, Cint, (Cint,), fd(io)) != 0)
    end
end

function syncdir(path::AbstractString)
    @static if Sys.isunix()
        descriptor = ccall(:open, Cint, (Cstring, Cint), dirname(abspath(path)), 0)
        Base.systemerror("open directory", descriptor < 0)
        try
            Base.systemerror("fsync directory", ccall(:fsync, Cint, (Cint,), descriptor) != 0)
        finally
            ccall(:close, Cint, (Cint,), descriptor)
        end
    end
    nothing
end

function claim(io::IOStream)
    @static if Sys.isunix()
        result = ccall(:flock, Cint, (Cint, Cint), fd(io), 6)
        if result != 0
            code = Base.Libc.errno()
            code == Base.Libc.EAGAIN && return Rejected(:locked)
            Base.systemerror("flock", code)
        end
        nothing
    else
        Rejected(:unsupported_platform)
    end
end

function recover(io::IOStream)
    seekstart(io)
    bytes = read(io)
    ends = findall(==(0x0a), bytes)
    state = State()
    start = 1
    for last in ends
        line = bytes[start:last-1]
        isvalid(String, line) || return Rejected(:corrupt_log)
        batch = try
            JSON3.read(String(line), Dict{String, Any})
        catch
            return Rejected(:corrupt_log)
        end
        replay!(state, batch) || return Rejected(:corrupt_log)
        start = last + 1
    end
    complete = isempty(ends) ? 0 : ends[end]
    if complete < length(bytes)
        truncate(io, complete)
        sync(io)
    end
    seekend(io)
    state
end

function Base.open(::Type{Store}, path::AbstractString)
    @static if !Sys.isunix()
        return Rejected(:unsupported_platform)
    end
    created = !isfile(path)
    io = open(path, "a+")
    success = false
    try
        result = claim(io)
        result === nothing || return result
        if created
            sync(io)
            syncdir(path)
        end
        state = recover(io)
        state isa Rejected && return state
        store = Store(io, state, state.nextid, ReentrantLock(), false, false, false)
        success = true
        store
    finally
        success || close(io)
    end
end

function Base.close(store::Store)
    lock(store.lock) do
        store.busy && return Rejected(:busy)
        if !store.closed
            store.closed = true
            close(store.io)
        end
    end
end

status(store::Store) = store.closed ? Rejected(:closed) : store.failed ? Rejected(:failed) : nothing
status(tx::Transaction) = !tx.active ? Rejected(:expired_transaction) : tx.owner !== current_task() ? Rejected(:foreign_task) : tx.failure

function revision(store::Store)
    lock(store.lock) do
        result = status(store)
        result === nothing ? store.state.seq : result
    end
end

selected(::Type{T}, record) where {T <: Record} = nothing
selected(::Type{T}, record::T) where {T <: Record} = deepcopy(record)
matches(::Type{T}, record, conversation) where {T <: Record} = false
matches(::Type{T}, record::T, conversation) where {T <: Record} = belongs(record, conversation)

function Base.get(store::Store, ::Type{T}, id::Integer) where {T <: Record}
    lock(store.lock) do
        result = status(store)
        result === nothing || return result
        record = get(store.state.records, id, nothing)
        selected(T, record)
    end
end

function Base.get(store::Store, ::Type{Submission}, conversation::Integer, request::AbstractString)
    lock(store.lock) do
        result = status(store)
        result === nothing || return result
        id = get(store.state.requests, (conversation, String(request)), nothing)
        id === nothing ? nothing : deepcopy(store.state.records[id])
    end
end

belongs(record::Conversation, conversation::Integer) = record.id == conversation
belongs(record::Record, conversation::Integer) = record.conversation == conversation
belongs(record::Record, ::Nothing) = true

function scan(store::Store, ::Type{T}; conversation::Union{Nothing, Integer}=nothing) where {T <: Record}
    lock(store.lock) do
        result = status(store)
        result === nothing || return result
        records = T[record for record in values(store.state.records) if matches(T, record, conversation)]
        sort!(records; by=record -> record.id)
        deepcopy(records)
    end
end

function Base.get(tx::Transaction, ::Type{T}, id::Integer) where {T <: Record}
    result = status(tx)
    result === nothing || return result
    record = get(tx.state.records, id, nothing)
    selected(T, record)
end

function mint!(tx::Transaction)
    result = status(tx)
    result === nothing || return result
    tx.store.nextid += 1
    id = tx.store.nextid
    push!(tx.minted, id)
    id
end

function reject!(tx::Transaction, reason::Symbol)
    tx.failure = Rejected(reason)
end

function put!(tx::Transaction, record::Record)
    result = status(tx)
    result === nothing || return result
    haskey(tx.state.records, record.id) || record.id in tx.minted || return reject!(tx, :unminted_id)
    saved = detach(record)
    result = apply!(tx.state, saved)
    result === nothing || return reject!(tx, result.reason)
    push!(tx.writes, saved)
    record.id
end

function submit!(tx::Transaction, conversation::Integer; request::Union{Nothing, String}=nothing, kind::String="input", value=nothing)
    result = status(tx)
    result === nothing || return result
    kind in ("input", "write", "continue") || return reject!(tx, :submission_type)
    if request !== nothing
        id = get(tx.state.requests, (conversation, request), nothing)
        if id !== nothing
            previous = tx.state.records[id]
            previous.kind == kind || return reject!(tx, :request_type)
            return id
        end
    end
    id = mint!(tx)
    put!(tx, Submission(id, conversation, request, kind, kind == "continue" ? "placed" : "queued", value))
end

function commit!(f, store::Store)
    lock(store.lock) do
        result = status(store)
        result === nothing || return result
        store.busy && return Rejected(:busy)
        store.busy = true
        try
            tx = Transaction(store, deepcopy(store.state), Record[], Set{Int}(), current_task(), true, nothing)
            value = try
                f(tx)
            finally
                tx.active = false
            end
            tx.failure === nothing || return tx.failure
            value = deepcopy(value)
            isempty(tx.writes) && return value
            seq = store.state.seq + 1
            encoded = JSON3.write((; seq, nextid=store.nextid, writes=encode.(tx.writes))) * "\n"
            adopted = false
            try
                seekend(store.io)
                write(store.io, encoded)
                sync(store.io)
                tx.state.seq = seq
                tx.state.nextid = store.nextid
                store.state = tx.state
                adopted = true
            finally
                adopted || (store.failed = true)
            end
            value
        finally
            store.busy = false
        end
    end
end

include("scheduler.jl")

end
