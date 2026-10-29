module Durable

using JSON3

struct Rejected
    reason::Symbol
end

abstract type Record end

struct Conversation <: Record
    id::Int
    value::Any
    parent::Union{Nothing, Tuple{Int, Int}}
end

Conversation(id, value) = Conversation(id, value, nothing)

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

encode(r::Conversation) = (; type="conversation", r.id, r.value, parent=isnothing(r.parent) ? nothing : (; conversation=r.parent[1], at=r.parent[2]))
encode(r::Entry) = (; type="entry", r.id, r.conversation, r.kind, r.value)
encode(r::Task) = (; type="task", r.id, r.conversation, r.state)
encode(r::Document) = (; type="document", r.id, r.conversation, r.value)
encode(r::Submission) = (; type="submission", r.id, r.conversation, r.request, r.kind, r.status, r.value)

function decode(row)
    type = row["type"]
    id = row["id"]
    id isa Int || return nothing
    if type == "conversation"
        parent = get(row, "parent", nothing)
        parent === nothing && return Conversation(id, row["value"])
        parent isa AbstractDict || return nothing
        conversation = get(parent, "conversation", nothing)
        at = get(parent, "at", nothing)
        conversation isa Int && at isa Int || return nothing
        return Conversation(id, row["value"], (conversation, at))
    end
    conversation = row["conversation"]
    conversation isa Int || return nothing
    type == "entry" && return Entry(id, conversation, row["kind"], row["value"])
    type == "task" && return Task(id, conversation, row["state"])
    type == "document" && return Document(id, conversation, row["value"])
    type == "submission" && return Submission(id, conversation, row["request"], row["kind"], row["status"], row["value"])
    nothing
end

detach(record::Record) = decode(JSON3.read(JSON3.write(encode(record)), Dict{String, Any}))

function visible(state::State, conversation::Int, id::Int)
    entry = get(state.records, id, nothing)
    entry isa Entry || return false
    upper = typemax(Int)
    while true
        entry.conversation == conversation && id <= upper && return true
        record = state.records[conversation]
        record.parent === nothing && return false
        conversation, at = record.parent
        upper = min(upper, at)
    end
end

function hasdocuments(state::State, conversation::Int)
    while true
        any(record isa Document && record.conversation == conversation for record in values(state.records)) && return true
        record = state.records[conversation]
        record.parent === nothing && return false
        conversation = record.parent[1]
    end
end

function forkcheck(state::State, record::Conversation)
    record.parent === nothing && return nothing
    conversation, at = record.parent
    get(state.records, conversation, nothing) isa Conversation || return Rejected(:conversation_missing)
    visible(state, conversation, at) || return Rejected(:fork_point_missing)
    hasdocuments(state, conversation) && return Rejected(:fork_documents_unsupported)
    nothing
end

function forkcheck(state::State, records::Vector{Record})
    for record in records
        record isa Conversation || continue
        result = forkcheck(state, record)
        result === nothing || return result
    end
    nothing
end

function apply!(state::State, record::Record)
    existing = get(state.records, record.id, nothing)
    record.id > 0 || return Rejected(:invalid_id)
    if existing !== nothing
        typeof(existing) === typeof(record) || return Rejected(:id_in_use)
        record isa Union{Conversation, Entry} && return Rejected(:immutable)
        existing.conversation == record.conversation || return Rejected(:immutable)
        if record isa Submission
            (existing.request, existing.kind) == (record.request, record.kind) || return Rejected(:immutable)
        end
    elseif record isa Conversation
        result = forkcheck(state, record)
        result === nothing || return result
    else
        get(state.records, record.conversation, nothing) isa Conversation || return Rejected(:conversation_missing)
    end
    if record isa Submission && record.request !== nothing
        key = (record.conversation, record.request)
        found = get(state.requests, key, record.id)
        found == record.id || return Rejected(:request_in_use)
        state.requests[key] = record.id
    end
    state.records[record.id] = record
    nothing
end

function replay!(state::State, row)
    try
        seq = row["seq"]
        seq isa Int && seq == state.seq + 1 || return false
        nextid = row["nextid"]
        nextid isa Int && nextid >= state.nextid || return false
        writes = row["writes"]
        writes isa AbstractVector && !isempty(writes) || return false
        records = Record[]
        for encoded in writes
            record = decode(encoded)
            record isa Record || return false
            record.id <= nextid || return false
            haskey(state.records, record.id) || record.id > state.nextid || return false
            if record isa Conversation
                forkcheck(state, record) === nothing || return false
            end
            push!(records, record)
        end
        for record in records
            apply!(state, record) === nothing || return false
        end
        forkcheck(state, records) === nothing || return false
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
        row = try
            JSON3.read(String(line), Dict{String, Any})
        catch
            return Rejected(:corrupt_log)
        end
        replay!(state, row) || return Rejected(:corrupt_log)
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

function Base.get(store::Store, ::Type{T}, id::Integer) where {T <: Record}
    lock(store.lock) do
        result = status(store)
        result === nothing || return result
        record = get(store.state.records, id, nothing)
        record isa T ? deepcopy(record) : nothing
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

function scan(store::Store, ::Type{T}; conversation::Union{Nothing, Integer}=nothing) where {T <: Record}
    lock(store.lock) do
        result = status(store)
        result === nothing || return result
        records = T[record for record in values(store.state.records) if record isa T && (conversation === nothing || belongs(record, conversation))]
        sort!(records; by=record -> record.id)
        deepcopy(records)
    end
end

function entries(state::State, conversation::Integer)
    get(state.records, conversation, nothing) isa Conversation || return Rejected(:conversation_missing)
    segments = Vector{Entry}[]
    upper = typemax(Int)
    while true
        segment = Entry[record for record in values(state.records) if record isa Entry && record.conversation == conversation && record.id <= upper]
        sort!(segment; by=record -> record.id)
        push!(segments, segment)
        record = state.records[conversation]
        record.parent === nothing && break
        conversation, at = record.parent
        upper = min(upper, at)
    end
    Entry[entry for segment in reverse(segments) for entry in segment]
end

function entries(store::Store, conversation::Integer)
    lock(store.lock) do
        result = status(store)
        result === nothing || return result
        deepcopy(entries(store.state, conversation))
    end
end

function entries(tx::Transaction, conversation::Integer)
    result = status(tx)
    result === nothing || return result
    deepcopy(entries(tx.state, conversation))
end

function Base.get(tx::Transaction, ::Type{T}, id::Integer) where {T <: Record}
    result = status(tx)
    result === nothing || return result
    record = get(tx.state.records, id, nothing)
    record isa T ? deepcopy(record) : nothing
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
    if record isa Conversation && !haskey(tx.state.records, record.id)
        result = forkcheck(tx.store.state, record)
        result === nothing || return reject!(tx, result.reason)
    end
    saved = detach(record)
    result = apply!(tx.state, saved)
    result === nothing || return reject!(tx, result.reason)
    push!(tx.writes, saved)
    record.id
end

function fork!(tx::Transaction, conversation::Integer, at::Integer; value=nothing)
    result = status(tx)
    result === nothing || return result
    id = mint!(tx)
    put!(tx, Conversation(id, value, (conversation, at)))
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
            result = forkcheck(tx.state, tx.writes)
            result === nothing || return result
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
