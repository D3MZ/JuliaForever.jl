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
    entries::Dict{Int, Int}
    documents::Dict{Int, Vector{Pair{Int, Document}}}
end

State() = State(0, 0, Dict{Int, Record}(), Dict{Tuple{Int, String}, Int}(), Dict{Int, Int}(), Dict{Int, Vector{Pair{Int, Document}}}())

abstract type Health end
struct Healthy <: Health end
struct Broken <: Health end
abstract type Access end
struct Open <: Access end
struct Closed <: Access end
abstract type Occupancy end
struct Free <: Occupancy end
struct Busy <: Occupancy end
abstract type Lifetime end
struct Live <: Lifetime end
struct Expired <: Lifetime end

const healthstates = Dict(false => Healthy(), true => Broken())
const accessstates = Dict(false => Open(), true => Closed())
const occupancystates = Dict(false => Free(), true => Busy())
const lifetimes = Dict(false => Expired(), true => Live())
health(value) = healthstates[convert(Bool, value)]
access(value) = accessstates[convert(Bool, value)]
occupancy(value) = occupancystates[convert(Bool, value)]
lifetime(value) = lifetimes[convert(Bool, value)]
failed(::Healthy) = false
failed(::Broken) = true
closed(::Open) = false
closed(::Closed) = true
busy(::Free) = false
busy(::Busy) = true
active(::Live) = true
active(::Expired) = false

mutable struct Store
    io::IOStream
    state::State
    nextid::Int
    lock::ReentrantLock
    health::Health
    access::Access
    occupancy::Occupancy

    function Store(io, state, nextid, lock, health::Health, access::Access, occupancy::Occupancy)
        new(io, state, nextid, lock, health, access, occupancy)
    end
end

Store(io, state, nextid, lock, failed, closed, busy) = Store(io, state, nextid, lock, health(failed), access(closed), occupancy(busy))

function Base.getproperty(store::Store, name::Symbol)
    name === :failed && return failed(getfield(store, :health))
    name === :closed && return closed(getfield(store, :access))
    name === :busy && return busy(getfield(store, :occupancy))
    getfield(store, name)
end

function Base.setproperty!(store::Store, name::Symbol, value)
    name === :failed && return failed(setfield!(store, :health, health(value)))
    name === :closed && return closed(setfield!(store, :access, access(value)))
    name === :busy && return busy(setfield!(store, :occupancy, occupancy(value)))
    setfield!(store, name, convert(fieldtype(Store, name), value))
end
Base.propertynames(::Store, private::Bool=false) = (:io, :state, :nextid, :lock, :failed, :closed, :busy, :health, :access, :occupancy)

mutable struct Transaction
    store::Store
    state::State
    writes::Vector{Record}
    minted::Set{Int}
    owner::Core.Task
    lifetime::Lifetime
    failure::Union{Nothing, Rejected}

    function Transaction(store, state, writes, minted, owner, lifetime::Lifetime, failure)
        new(store, state, writes, minted, owner, lifetime, failure)
    end
end

Transaction(store, state, writes, minted, owner, active, failure) = Transaction(store, state, writes, minted, owner, lifetime(active), failure)
function Base.getproperty(tx::Transaction, name::Symbol)
    name === :active && return active(getfield(tx, :lifetime))
    getfield(tx, name)
end
function Base.setproperty!(tx::Transaction, name::Symbol, value)
    name === :active && return active(setfield!(tx, :lifetime, lifetime(value)))
    setfield!(tx, name, convert(fieldtype(Transaction, name), value))
end
Base.propertynames(::Transaction, private::Bool=false) = (:store, :state, :writes, :minted, :owner, :active, :failure, :lifetime)

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

validate(::Conversation) = nothing
validate(parent) = Rejected(:conversation_missing)
validate(state::State, ::Nothing, record::Conversation) = forkcheck(state, record)
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
    index!(state, record)
    nothing
end

index!(state::State, record::Record) = nothing
index!(state::State, record::Entry) = (state.entries[record.id] = state.seq + 1; nothing)
function index!(state::State, record::Document)
    push!(get!(Vector{Pair{Int, Document}}, state.documents, record.id), (state.seq + 1) => record)
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
        close(store, getfield(store, :occupancy))
    end
end
Base.close(store::Store, ::Busy) = Rejected(:busy)
Base.close(store::Store, ::Free) = close(store, getfield(store, :access))
Base.close(store::Store, ::Closed) = nothing
function Base.close(store::Store, ::Open)
    setfield!(store, :access, Closed())
    close(store.io)
end

status(store::Store) = status(getfield(store, :access), getfield(store, :health))
status(::Closed, ::Health) = Rejected(:closed)
status(::Open, ::Broken) = Rejected(:failed)
status(::Open, ::Healthy) = nothing
status(tx::Transaction) = status(tx, getfield(tx, :lifetime))
status(tx::Transaction, ::Expired) = Rejected(:expired_transaction)
status(tx::Transaction, ::Live) = tx.owner !== current_task() ? Rejected(:foreign_task) : tx.failure

function revision(store::Store)
    lock(store.lock) do
        revision(store, status(store))
    end
end
revision(store::Store, rejected::Rejected) = rejected
revision(store::Store, ::Nothing) = store.state.seq

selected(::Type{T}, record) where {T <: Record} = nothing
selected(::Type{T}, record::T) where {T <: Record} = deepcopy(record)
matches(::Type{T}, record, conversation) where {T <: Record} = false
matches(::Type{T}, record::T, conversation) where {T <: Record} = belongs(record, conversation)

function Base.get(store::Store, ::Type{T}, id::Integer) where {T <: Record}
    lock(store.lock) do
        readrecord(store, T, id, status(store))
    end
end
readrecord(owner, type, id, rejected::Rejected) = rejected
readrecord(owner, type, id, ::Nothing) = selected(type, get(owner.state.records, id, nothing))

function Base.get(store::Store, ::Type{Submission}, conversation::Integer, request::AbstractString)
    lock(store.lock) do
        readsubmission(store, conversation, request, status(store))
    end
end
readsubmission(store, conversation, request, rejected::Rejected) = rejected
readsubmission(store, conversation, request, ::Nothing) = readsubmission(store, get(store.state.requests, (conversation, String(request)), nothing))
readsubmission(store, ::Nothing) = nothing
readsubmission(store, id::Integer) = deepcopy(store.state.records[id])

belongs(record::Conversation, conversation::Integer) = record.id == conversation
belongs(record::Record, conversation::Integer) = record.conversation == conversation
belongs(record::Record, ::Nothing) = true

function scan(store::Store, ::Type{T}; conversation::Union{Nothing, Integer}=nothing) where {T <: Record}
    lock(store.lock) do
        scan(store, T, conversation, status(store))
    end
end
scan(store, type, conversation, rejected::Rejected) = rejected
function scan(store, ::Type{T}, conversation, ::Nothing) where {T <: Record}
    records = T[record for record in values(store.state.records) if matches(T, record, conversation)]
    sort!(records; by=record -> record.id)
    deepcopy(records)
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
function snapshot(store::Store, conversation::Integer, document::Integer, entry::Integer)
    lock(store.lock) do
        snapshot(store.state, conversation, document, entry, status(store))
    end
end
snapshot(state, conversation, document, entry, rejected::Rejected) = rejected
snapshot(state, conversation, document, entry, ::Nothing) = snapshotentry(state, conversation, document, get(state.records, entry, nothing))
snapshotentry(state, conversation, document, ::Union{Nothing, Record}) = Rejected(:entry_not_visible)
function snapshotentry(state, conversation, document, entry::Entry)
    entry.conversation == conversation || return Rejected(:entry_not_visible)
    snapshotdocument(state, conversation, state.entries[entry.id], get(state.records, document, nothing))
end
snapshotdocument(state, conversation, seq, ::Union{Nothing, Record}) = nothing
function snapshotdocument(state, conversation, seq, document::Document)
    document.conversation == conversation || return nothing
    versions = state.documents[document.id]
    snapshotversion(versions, findlast(version -> version.first <= seq, versions))
end
snapshotversion(versions, ::Nothing) = nothing
snapshotversion(versions, index::Integer) = deepcopy(versions[index].second)

Base.get(tx::Transaction, ::Type{T}, id::Integer) where {T <: Record} = readrecord(tx, T, id, status(tx))
mint!(tx::Transaction) = mint!(tx, status(tx))
mint!(tx::Transaction, rejected::Rejected) = rejected
function mint!(tx::Transaction, ::Nothing)
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

put!(tx::Transaction, record::Record) = put_ready!(tx, record, status(tx))
put_ready!(tx::Transaction, record::Record, rejected::Rejected) = rejected
function put_ready!(tx::Transaction, record::Record, ::Nothing)
    haskey(tx.state.records, record.id) || record.id in tx.minted || return reject!(tx, :unminted_id)
    put_checked!(tx, record, forkcheck(tx, record))
end

put_checked!(tx::Transaction, ::Record, result::Rejected) = reject!(tx, result.reason)
function put_checked!(tx::Transaction, record::Record, ::Nothing)
    saved = detach(record)
    put_saved!(tx, record, saved, apply!(tx.state, saved))
end
put_saved!(tx, record, saved, rejected::Rejected) = reject!(tx, rejected.reason)
function put_saved!(tx, record, saved, ::Nothing)
    push!(tx.writes, saved)
    record.id
end

fork!(tx::Transaction, conversation::Integer, at::Integer; value=nothing) = fork!(tx, conversation, at, status(tx); value)
fork!(::Transaction, ::Integer, ::Integer, result::Rejected; value=nothing) = result
function fork!(tx::Transaction, conversation::Integer, at::Integer, ::Nothing; value=nothing)
    id = mint!(tx)
    put!(tx, Conversation(id, value, (conversation, at)))
end

const submissionstates = Dict("input" => "queued", "write" => "queued", "continue" => "placed")
function submit!(tx::Transaction, conversation::Integer; request::Union{Nothing, String}=nothing, kind::String="input", value=nothing)
    submit!(tx, conversation, request, kind, value, status(tx))
end
submit!(tx, conversation, request, kind, value, rejected::Rejected) = rejected
submit!(tx, conversation, request, kind, value, ::Nothing) = submit_kind!(tx, conversation, request, kind, value, get(submissionstates, kind, nothing))
submit_kind!(tx, conversation, request, kind, value, ::Nothing) = reject!(tx, :submission_type)
submit_kind!(tx, conversation, request, kind, value, state::String) = submit_request!(tx, conversation, request, kind, value, state)
submit_request!(tx, conversation, ::Nothing, kind, value, state) = newsubmission!(tx, conversation, nothing, kind, value, state)
submit_request!(tx, conversation, request::String, kind, value, state) = submit_existing!(tx, conversation, request, kind, value, state, get(tx.state.requests, (conversation, request), nothing))
submit_existing!(tx, conversation, request, kind, value, state, ::Nothing) = newsubmission!(tx, conversation, request, kind, value, state)
function submit_existing!(tx, conversation, request, kind, value, state, id::Integer)
    previous = tx.state.records[id]
    previous.kind == kind || return reject!(tx, :request_type)
    id
end
function newsubmission!(tx, conversation, request, kind, value, state)
    id = mint!(tx)
    put!(tx, Submission(id, conversation, request, kind, state, value))
end

function commit!(f, store::Store)
    lock(store.lock) do
        commit!(f, store, status(store))
    end
end
commit!(f, store::Store, rejected::Rejected) = rejected
commit!(f, store::Store, ::Nothing) = commit!(f, store, getfield(store, :occupancy))
commit!(f, store::Store, ::Busy) = Rejected(:busy)

function commit!(f, store::Store, ::Free)
    setfield!(store, :occupancy, Busy())
    try
        tx = Transaction(store, deepcopy(store.state), Record[], Set{Int}(), current_task(), true, nothing)
        value = try
            f(tx)
        finally
            setfield!(tx, :lifetime, Expired())
        end
        committed!(store, tx, value, tx.failure)
    finally
        setfield!(store, :occupancy, Free())
    end
end

committed!(store::Store, tx::Transaction, value, rejected::Rejected) = rejected
committed!(store::Store, tx::Transaction, value, ::Nothing) = commit!(store, tx, value, forkcheck(tx.state, tx.writes))

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
        adopted || setfield!(store, :health, Broken())
    end
    value
end

include("scheduler.jl")

end
