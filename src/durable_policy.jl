const documentpolicies = Dict("asOf" => AsOf(), "current" => Current(), "initial" => Initial())

decodepolicy(id, conversation, kind, key, policy, value) = nothing
decodepolicy(id, conversation, kind::String, key::Union{Nothing, String}, policy::DocumentPolicy, value) = PolicyDocument(id, conversation, kind, key, policy, value)
decodefork(id, value, parent, copies) = nothing
decodefork(id, value, parent::AbstractDict, copies::AbstractVector) = decodefork(id, value, get(parent, "conversation", nothing), get(parent, "at", nothing), copies)
decodefork(id, value, conversation, at, copies) = nothing
decodefork(id, value, conversation::Int, at::Int, copies::AbstractVector) = DocumentFork(id, value, (conversation, at), ForkCopy[decodecopy(copy) for copy in copies])
decodecopy(copy::AbstractDict) = decodecopy(copy["id"], copy["source"])
decodecopy(id::Int, source::Int) = ForkCopy(id, source)

address(record::PolicyDocument) = (record.conversation, record.kind, record.key)
member(record::PolicyDocument) = (record.kind, record.key)
documentidentity(record::PolicyDocument) = (address(record), record.policy)
validate(existing::PolicyDocument, record::PolicyDocument) = documentidentity(existing) == documentidentity(record) ? nothing : Rejected(:immutable)

function register!(state::State, record::PolicyDocument)
    key = address(record)
    get(state.addresses, key, record.id) == record.id || return Rejected(:document_address_in_use)
    state.addresses[key] = record.id
    nothing
end

function index!(state::State, record::PolicyDocument)
    push!(get!(Vector{Pair{Int, PolicyDocument}}, state.policies, record.id), (state.seq + 1) => record)
    nothing
end

snapshotdocument(state, conversation, seq, document::PolicyDocument) = snapshotdocument(state, conversation, seq, document, state.policies)

function ancestors(state::State, conversation::Int)
    result = Int[]
    pending = Tuple{Int, Int}[(conversation, typemax(Int))]
    while !isempty(pending)
        id, upper = pop!(pending)
        push!(result, id)
        pushparent!(pending, state.records[id], upper)
    end
    result
end

opaquecheck(result::Rejected, record, conversations) = result
opaquecheck(::Nothing, ::Record, conversations) = nothing
function opaquecheck(::Nothing, record::Document, conversations)
    record.conversation in conversations && return Rejected(:fork_documents_unsupported)
    nothing
end
function opaquecheck(state::State, conversation::Int)
    conversations = ancestors(state, conversation)
    foldl((result, record) -> opaquecheck(result, record, conversations), values(state.records); init=nothing)
end

forkplan(state::State, conversation::Int, at::Int) = forkparent(state, conversation, at, get(state.records, conversation, nothing))
forkparent(state, conversation, at, parent) = Rejected(:conversation_missing)
function forkparent(state, conversation, at, ::Conversation)
    index = findfirst(entry -> entry.id == at, entries(state, conversation))
    forkvisible(state, conversation, at, index)
end
forkvisible(state, conversation, at, ::Nothing) = Rejected(:fork_point_missing)
forkvisible(state, conversation, at, ::Int) = forkpoint(state, conversation, state.records[at], opaquecheck(state, conversation))
forkpoint(state, conversation, entry, rejected::Rejected) = rejected
function forkpoint(state, conversation, entry::Entry, ::Nothing)
    sources = foldl((sources, record) -> selectfork!(sources, state, conversation, entry, record), values(state.records); init=PolicyDocument[])
    sort!(sources; by=source -> source.id)
    allunique(member.(sources)) || return Rejected(:fork_document_address_in_use)
    sources
end

selectfork!(sources, state, conversation, entry, ::Record) = sources
function selectfork!(sources, state, conversation, entry, document::PolicyDocument)
    selectasof!(sources, state, entry, document, document.policy)
    selectcurrent!(sources, conversation, document, document.policy)
    sources
end
selectasof!(sources, state, entry, document, ::DocumentPolicy) = sources
function selectasof!(sources, state, entry, document, ::AsOf)
    selected!(sources, snapshotdocument(state, entry.conversation, state.entries[entry.id], document))
end
selected!(sources, ::Nothing) = sources
selected!(sources, document::PolicyDocument) = push!(sources, document)
selectcurrent!(sources, conversation, document, ::DocumentPolicy) = sources
function selectcurrent!(sources, conversation, document, ::Current)
    document.conversation == conversation && push!(sources, document)
    sources
end

forkpolicy!(tx, parent, value, rejected::Rejected) = reject!(tx, rejected.reason)
forkpolicy!(tx, parent, value, sources::Vector{PolicyDocument}) = forkpolicy!(tx, parent, value, sources, sourcecheck(tx.writes, ancestors(tx.store.state, parent[1])))
forkpolicy!(tx, parent, value, sources, rejected::Rejected) = reject!(tx, rejected.reason)
function forkpolicy!(tx, parent, value, sources, ::Nothing)
    id = mint!(tx)
    copies = [ForkCopy(mint!(tx), source.id) for source in sources]
    put!(tx, DocumentFork(id, value, parent, copies))
end

function put_ready!(tx::Transaction, record::DocumentFork, ::Nothing)
    record.id in tx.minted || return reject!(tx, :unminted_id)
    all(copy -> copy.id in tx.minted, record.copies) || return reject!(tx, :unminted_id)
    put_checked!(tx, record, nothing)
end

replayids(state, nextid, ::Record) = nothing
replayids(state, nextid, record::DocumentFork) = foldl((result, copy) -> replaycopyid(result, state, nextid, copy), record.copies; init=nothing)
replaycopyid(rejected::Rejected, state, nextid, copy) = rejected
function replaycopyid(::Nothing, state, nextid, copy)
    state.nextid < copy.id <= nextid || return Rejected(:corrupt_log)
    nothing
end

plancheck(record::DocumentFork, rejected::Rejected) = rejected
function plancheck(record::DocumentFork, sources::Vector{PolicyDocument})
    [copy.source for copy in record.copies] == [source.id for source in sources] || return Rejected(:fork_copy_mismatch)
    allunique([record.id; [copy.id for copy in record.copies]]) || return Rejected(:id_in_use)
    nothing
end

batchforkcheck(state::State, writes::Vector{Record}) = foldl((result, record) -> batchforkcheck(state, writes, record, result), writes; init=nothing)
batchforkcheck(state, writes, record, rejected::Rejected) = rejected
batchforkcheck(state, writes, ::Record, ::Nothing) = nothing
function batchforkcheck(state, writes, record::DocumentFork, ::Nothing)
    plan = forkplan(state, record.parent...)
    batchforkchecked(state, writes, record, plancheck(record, plan))
end
batchforkchecked(state, writes, record, rejected::Rejected) = rejected
function batchforkchecked(state, writes, record, ::Nothing)
    conversations = ancestors(state, record.parent[1])
    sourcecheck(writes, conversations)
end
sourcecheck(writes, conversations) = foldl((result, write) -> sourcecheck(result, write, conversations), writes; init=nothing)
sourcecheck(rejected::Rejected, write, conversations) = rejected
sourcecheck(::Nothing, ::Record, conversations) = nothing
function sourcecheck(::Nothing, write::Document, conversations)
    write.conversation in conversations && return Rejected(:fork_documents_unsupported)
    nothing
end
function sourcecheck(::Nothing, write::PolicyDocument, conversations)
    write.conversation in conversations && return Rejected(:fork_source_modified)
    nothing
end

function apply!(state::State, record::DocumentFork)
    record.id > 0 || return Rejected(:invalid_id)
    sources = forkplan(state, record.parent...)
    applyfork!(state, record, sources, plancheck(record, sources))
end
applyfork!(state, record, sources, rejected::Rejected) = rejected
function applyfork!(state, record, sources::Vector{PolicyDocument}, ::Nothing)
    haskey(state.records, record.id) && return Rejected(:id_in_use)
    result = store!(state, Conversation(record.id, record.value, record.parent), nothing)
    foldl((result, pair) -> applycopy!(state, record, pair, result), zip(record.copies, sources); init=result)
end
applycopy!(state, record, pair, rejected::Rejected) = rejected
function applycopy!(state, record, (copy, source), ::Nothing)
    apply!(state, PolicyDocument(copy.id, record.id, source.kind, source.key, source.policy, deepcopy(source.value)))
end
