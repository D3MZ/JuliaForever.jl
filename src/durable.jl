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

encode(::Nothing) = nothing
encode(parent::Tuple{Int, Int}) = (; conversation=parent[1], at=parent[2])
encode(r::Conversation) = (; type="conversation", r.id, r.value, parent=encode(r.parent))
encode(r::Entry) = (; type="entry", r.id, r.conversation, r.kind, r.value)
encode(r::Task) = (; type="task", r.id, r.conversation, r.state)
encode(r::Document) = (; type="document", r.id, r.conversation, r.value)
encode(r::Submission) = (; type="submission", r.id, r.conversation, r.request, r.kind, r.status, r.value)

const recordtypes = Dict("conversation" => Conversation, "entry" => Entry, "task" => Task, "document" => Document, "submission" => Submission)

decode(record::AbstractDict) = decode(get(recordtypes, record["type"], nothing), record, record["id"])
decode(::Nothing, record, id) = nothing
decode(::Type{<:Record}, record, id) = nothing
decode(::Type{Conversation}, record, id::Int) = decodeparent(id, record["value"], get(record, "parent", nothing))
decode(type::Type{<:Record}, record, id::Int) = decode(type, record, id, record["conversation"])
decode(::Type{<:Record}, record, id::Int, conversation) = nothing
decode(::Type{Entry}, record, id::Int, conversation::Int) = Entry(id, conversation, record["kind"], record["value"])
decode(::Type{Task}, record, id::Int, conversation::Int) = Task(id, conversation, record["state"])
decode(::Type{Document}, record, id::Int, conversation::Int) = Document(id, conversation, record["value"])
decode(::Type{Submission}, record, id::Int, conversation::Int) = Submission(id, conversation, record["request"], record["kind"], record["status"], record["value"])

decodeparent(id, value, ::Nothing) = Conversation(id, value)
decodeparent(id, value, parent::AbstractDict) = decodeparent(id, value, get(parent, "conversation", nothing), get(parent, "at", nothing))
decodeparent(id, value, parent) = nothing
decodeparent(id, value, conversation::Int, at::Int) = Conversation(id, value, (conversation, at))
decodeparent(id, value, conversation, at) = nothing

detach(record::Record) = decode(JSON3.read(JSON3.write(encode(record)), Dict{String, Any}))

pushparent!(pending, ::Nothing, upper) = nothing
pushparent!(pending, parent::Tuple{Int, Int}, upper) = push!(pending, (parent[1], min(upper, parent[2])))
pushparent!(pending, record::Conversation, upper) = pushparent!(pending, record.parent, upper)

visible(state::State, conversation::Int, id::Int) = visible(state, conversation, id, get(state.records, id, nothing))
visible(::State, ::Int, ::Int, entry) = false
function visible(state::State, conversation::Int, id::Int, entry::Entry)
    pending = Tuple{Int, Int}[(conversation, typemax(Int))]
    while !isempty(pending)
        conversation, upper = pop!(pending)
        entry.conversation == conversation && id <= upper && return true
        pushparent!(pending, state.records[conversation], upper)
    end
    false
end

document(::Record, conversation) = false
document(record::Document, conversation) = record.conversation == conversation

function hasdocuments(state::State, conversation::Int)
    pending = Tuple{Int, Int}[(conversation, typemax(Int))]
    while !isempty(pending)
        conversation, upper = pop!(pending)
        any(document(record, conversation) for record in values(state.records)) && return true
        pushparent!(pending, state.records[conversation], upper)
    end
    false
end

forkcheck(::State, ::Record) = nothing
forkcheck(state::State, record::Conversation) = forkcheck(state, record.parent)
forkcheck(::State, ::Nothing) = nothing
forkcheck(state::State, parent::Tuple{Int, Int}) = forkcheck(state, parent, get(state.records, parent[1], nothing))
forkcheck(::State, ::Tuple{Int, Int}, parent) = Rejected(:conversation_missing)
function forkcheck(state::State, parent::Tuple{Int, Int}, ::Conversation)
    conversation, at = parent
    visible(state, conversation, at) || return Rejected(:fork_point_missing)
    hasdocuments(state, conversation) && return Rejected(:fork_documents_unsupported)
    nothing
end

forkcheck(state::State, records::Vector{Record}) = foldl((result, record) -> forkcheck(state, record, result), records; init=nothing)
forkcheck(state::State, record::Record, ::Nothing) = forkcheck(state, record)
forkcheck(::State, ::Record, result::Rejected) = result

valid(::Nothing) = true
valid(result) = false

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
    else
        return applynew!(state, record)
    end
    save!(state, record)
end

applynew!(state::State, record::Conversation) = applynew!(state, record, forkcheck(state, record))
applynew!(state::State, record::Conversation, ::Nothing) = save!(state, record)
applynew!(::State, ::Conversation, result::Rejected) = result
applynew!(state::State, record::Record) = applynew!(state, record, get(state.records, record.conversation, nothing))
applynew!(state::State, record::Record, ::Conversation) = save!(state, record)
applynew!(::State, ::Record, parent) = Rejected(:conversation_missing)

function save!(state::State, record::Record)
    if record isa Submission && record.request !== nothing
        key = (record.conversation, record.request)
        found = get(state.requests, key, record.id)
        found == record.id || return Rejected(:request_in_use)
        state.requests[key] = record.id
    end
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
        records = Record[]
        for encoded in writes
            record = decode(encoded)
            record isa Record || return false
            record.id <= nextid || return false
            haskey(state.records, record.id) || record.id > state.nextid || return false
            valid(forkcheck(state, record)) || return false
            push!(records, record)
        end
        for record in records
            valid(apply!(state, record)) || return false
        end
        valid(forkcheck(state, records)) || return false
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

entry(::Record, conversation, upper) = false
entry(record::Entry, conversation, upper) = record.conversation == conversation && record.id <= upper

entries(state::State, conversation::Integer) = entries(state, conversation, get(state.records, conversation, nothing))
entries(::State, ::Integer, record) = Rejected(:conversation_missing)
function entries(state::State, conversation::Integer, ::Conversation)
    segments = Vector{Entry}[]
    pending = Tuple{Int, Int}[(conversation, typemax(Int))]
    while !isempty(pending)
        conversation, upper = pop!(pending)
        segment = Entry[record for record in values(state.records) if entry(record, conversation, upper)]
        sort!(segment; by=record -> record.id)
        push!(segments, segment)
        pushparent!(pending, state.records[conversation], upper)
    end
    Entry[entry for segment in reverse(segments) for entry in segment]
end

copyentries(state::State, conversation::Integer, ::Nothing) = deepcopy(entries(state, conversation))
copyentries(::State, ::Integer, result::Rejected) = result

function entries(store::Store, conversation::Integer)
    lock(store.lock) do
        copyentries(store.state, conversation, status(store))
    end
end

entries(tx::Transaction, conversation::Integer) = copyentries(tx.state, conversation, status(tx))

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

forkcheck(::Transaction, ::Record) = nothing
forkcheck(tx::Transaction, record::Conversation) = forkcheck(tx, record, get(tx.state.records, record.id, nothing))
forkcheck(tx::Transaction, record::Conversation, ::Nothing) = forkcheck(tx.store.state, record)
forkcheck(::Transaction, ::Conversation, ::Record) = nothing

function put!(tx::Transaction, record::Record)
    result = status(tx)
    result === nothing || return result
    haskey(tx.state.records, record.id) || record.id in tx.minted || return reject!(tx, :unminted_id)
    put!(tx, record, forkcheck(tx, record))
end

put!(tx::Transaction, ::Record, result::Rejected) = reject!(tx, result.reason)
function put!(tx::Transaction, record::Record, ::Nothing)
    saved = detach(record)
    result = apply!(tx.state, saved)
    result === nothing || return reject!(tx, result.reason)
    push!(tx.writes, saved)
    record.id
end

fork!(tx::Transaction, conversation::Integer, at::Integer; value=nothing) = fork!(tx, conversation, at, status(tx); value)
fork!(::Transaction, ::Integer, ::Integer, result::Rejected; value=nothing) = result
function fork!(tx::Transaction, conversation::Integer, at::Integer, ::Nothing; value=nothing)
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
            commit!(store, tx, value, forkcheck(tx.state, tx.writes))
        finally
            store.busy = false
        end
    end
end

commit!(::Store, ::Transaction, value, result::Rejected) = result
function commit!(store::Store, tx::Transaction, value, ::Nothing)
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
end

include("scheduler.jl")

end
