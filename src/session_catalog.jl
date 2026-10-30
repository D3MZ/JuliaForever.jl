module SessionCatalog

using Random, SHA
import ..History as H
import ..Conversation as C
import ..Kernel as K
import Base: append!

abstract type Request end
struct New <: Request end
struct Recent <: Request end
struct Picker <: Request end
struct Ephemeral <: Request end
struct Target <: Request
    value::String
end
struct Fork <: Request
    value::String
end
struct Explicit <: Request
    path::String
end
struct Conflict <: Request end

assign(::New, request::Request) = request
assign(::Request, ::Request) = Conflict()
assign(::Ephemeral, ::Request) = Ephemeral()
assign(::Request, ::Ephemeral) = Ephemeral()
assign(::New, ::Ephemeral) = Ephemeral()
assign(::Ephemeral, ::Ephemeral) = Ephemeral()
assign(::Explicit, ::Ephemeral) = Conflict()
assign(::Ephemeral, ::Explicit) = Conflict()
assign(::Fork, ::Ephemeral) = Conflict()
assign(::Ephemeral, ::Fork) = Conflict()
assign(::Conflict, ::Ephemeral) = Conflict()

recovery(::Request) = false
recovery(::Explicit) = true

struct Cancelled end
struct Invalid
    message::String
end

struct Info
    path::String
    id::String
    title::String
    modified::Float64
end

directory(env) = abspath(expanduser(get(env, "JF_SESSION_DIR", joinpath(homedir(), ".julia", "juliaforever", "sessions"))))
project(cwd) = bytes2hex(sha256(abspath(cwd)))[1:24]
filename(cwd, id) = project(cwd) * "--" * id * ".sqlite"

mutable struct Deferred <: H.Store
    path::String
    store::H.Store
    lock::ReentrantLock
end

Deferred(path) = Deferred(path, H.Memory(), ReentrantLock())
new(dir, cwd) = H.Tree(Deferred(joinpath(dir, filename(cwd, bytes2hex(rand(UInt8, 16))))))

function H.snapshot(history::Deferred)
    lock(history.lock) do
        H.snapshot(history.store)
    end
end

function append!(history::Deferred, revision::Integer, batch::Vector)
    lock(history.lock) do
        append!(history, history.store, revision, batch)
    end
end

append!(history::Deferred, store::H.SQLite, revision, batch) = append!(store, revision, batch)
append!(history::Deferred, store::H.Memory, revision, batch) = materialize!(history, store, revision, batch, append!(store, revision, batch))
materialize!(history, store::H.Memory, revision, batch, rejected::H.Rejected) = rejected
materialize!(history, store::H.Memory, revision, batch, saved::Integer) = revision == 0 ? saved : materialize!(history, store, saved, H.treenode(batch, 0))
materialize!(history, store::H.Memory, saved::Integer, ::H.Rejected) = materialize!(history, store, H.snapshot(store))
materialize!(history, store::H.Memory, saved::Integer, node::H.TreeNode) = length(node.batch) == 1 ? materialize!(history, store, saved, H.decode_event(only(node.batch))) : materialize!(history, store, H.snapshot(store))
materialize!(history, store::H.Memory, saved::Integer, ::C.SessionName) = saved
materialize!(history, store::H.Memory, saved::Integer, ::C.BashOutput) = saved
materialize!(history, store::H.Memory, saved::Integer, ::C.SessionRecord) = saved
materialize!(history, store::H.Memory, saved::Integer, event) = materialize!(history, store, H.snapshot(store))

function materialize!(history, store::H.Memory, snapshot::H.Snapshot)
    mkpath(dirname(history.path))
    file = Base.Filesystem.open(history.path, Base.JL_O_WRONLY | Base.JL_O_CREAT | Base.JL_O_EXCL, 0o600)
    close(file)
    materialize!(history, open(H.SQLite, history.path), snapshot)
end

materialize!(history, rejected::H.Rejected, snapshot) = rejected

function materialize!(history, store::H.SQLite, snapshot::H.Snapshot)
    history.store = store
    foldl(snapshot.batches; init=0) do revision, batch
        appendbatch!(store, revision, batch)
    end
end

appendbatch!(store, rejected::H.Rejected, batch) = rejected
appendbatch!(store, revision::Integer, batch) = append!(store, revision, batch)
closehistory(::H.Memory) = nothing
closehistory(store::H.SQLite) = close(store)
path(history::Deferred) = history.path
path(history::H.SQLite) = history.db.file
path(history::H.Tree) = path(history.store)

function Base.close(history::Deferred)
    lock(history.lock) do
        closehistory(history.store)
    end
end

firstprompt(text, event) = text
firstprompt(::Nothing, event::Union{C.Input, C.ImageInput}) = event.text
firstprompt(::Nothing, event) = nothing

function firstprompt(snapshot::H.Snapshot)
    foldl(snapshot.batches[2:end]; init=nothing) do text, batch
        foldl(batch; init=text) do value, record
            firstprompt(value, H.decode_event(record))
        end
    end
end

firstprompt(::H.Rejected) = nothing

function firstprompt(entries::Vector)
    foldl(entries[2:end]; init=nothing) do text, entry
        foldl(entry.batch; init=text) do value, record
            firstprompt(value, H.decode_event(record))
        end
    end
end

sessionname(current, ::Any) = current
sessionname(current, event::C.SessionName) = isempty(event.name) ? nothing : event.name
sessionname(current, batch::AbstractVector) = foldl((value, record) -> sessionname(value, H.decode_event(record)), batch; init=current)
sessionname(batches::AbstractVector{<:AbstractVector}) = foldl(sessionname, batches; init=nothing)
sessionname(entries::AbstractVector{<:NamedTuple}) = foldl((value, entry) -> sessionname(value, entry.batch), entries; init=nothing)
sessionname(snapshot::H.Snapshot) = sessionname(snapshot.batches)
sessionname(rejected::H.Rejected) = rejected
sessionname(history::H.Tree) = sessionname(H.entries(history))
sessionname(history::H.Store) = sessionname(H.snapshot(history))
sessionname(::Nothing) = nothing

title(::Nothing, fallback) = fallback
title(name::String, fallback) = name
title(rejected::H.Rejected, fallback) = rejected
title(entries::Vector) = title(sessionname(entries), firstprompt(entries))
title(snapshot::H.Snapshot) = title(sessionname(snapshot), firstprompt(snapshot))
title(rejected::H.Rejected) = rejected

info(path, id, ::Nothing) = nothing
function modified(path)
    time = stat(path).mtime
    wal = path * "-wal"
    isfile(wal) ? max(time, stat(wal).mtime) : time
end

info(path, id, title::String) = Info(path, id, title, modified(path))
info(path, id, ::H.Rejected) = Info(path, id, "Unavailable session", modified(path))
info(path, id, snapshot::H.Snapshot) = info(path, id, title(snapshot))
info(path, id, tree::H.Tree) = info(path, id, title(H.entries(tree)))

function info(path, id, store::H.SQLite)
    try
        info(path, id, H.Tree(store))
    finally
        close(store)
    end
end

pushinfo!(items, ::Nothing) = items
pushinfo!(items, item::Info) = (push!(items, item); items)

function list(dir, cwd::AbstractString)
    pattern = Regex("^" * project(cwd) * raw"--([0-9a-f]{32})\.sqlite$")
    list(dir, pattern)
end

function list(dir, pattern::Regex)
    isdir(dir) || return Info[]
    items = Info[]
    for file in readdir(dir)
        found = match(pattern, file)
        collectinfo!(items, dir, file, found)
    end
    sort!(items; by=item -> (item.modified, item.path), rev=true)
end

collectinfo!(items, dir, file, ::Nothing) = items

function collectinfo!(items, dir, file, found::RegexMatch)
    path = joinpath(dir, file)
    pushinfo!(items, info(path, String(found.captures[1]), open(H.SQLite, path; create=false)))
end

wrap(rejected::H.Rejected) = rejected
function wrap(store::H.SQLite)
    result = nothing
    try
        result = H.Tree(store)
    finally
        release!(store, result)
    end
    result
end

release!(store::H.SQLite, ::H.Tree) = nothing
release!(store::H.SQLite, ::H.SQLite) = nothing
release!(store::H.SQLite, result) = close(store)

istree(record) = false
istree(record::Dict) = get(record, "format", "") == H.treeformat
istree(batch::Vector) = any(istree, batch)

adapt(rejected::H.Rejected) = rejected
function adapt(store::H.SQLite)
    result = nothing
    try
        result = adapt(store, H.snapshot(store))
    finally
        release!(store, result)
    end
    result
end

adapt(store::H.SQLite, rejected::H.Rejected) = rejected
adapt(store::H.SQLite, snapshot::H.Snapshot) = any(istree, snapshot.batches) ? H.Tree(store) : store

openinfo(info::Info) = wrap(open(H.SQLite, info.path; create=false))
choose(request::Request, dir, cwd, input, output, redact) = choose(request, dir, cwd, input, output)
choose(::New, dir, cwd, input, output) = new(dir, cwd)
choose(::Ephemeral, dir, cwd, input, output) = H.Tree(H.Memory())
choose(request::Explicit, dir, cwd, input, output) = adapt(open(H.SQLite, request.path))
choose(::Conflict, dir, cwd, input, output) = Invalid("Choose only one session option.")
choose(request::Fork, dir, cwd, input, output, redact=identity) = fork(source(request, dir, cwd, redact), dir, cwd)

function source(request::Fork, dir, cwd, redact)
    path = expanduser(request.value)
    isfile(path) && return wrap(open(H.SQLite, path; create=false))
    matches = filter(item -> occursin(lowercase(request.value), item.id), list(dir, cwd))
    source(matches, request.value, dir, redact)
end
function source(matches::Vector{Info}, value, dir, redact)
    isempty(matches) && return named(filter(item -> occursin(lowercase(value), item.id), listall(dir)), value, redact)
    named(matches, value, redact)
end

listall(dir) = list(dir, r"^[0-9a-f]{24}--([0-9a-f]{32})\.sqlite$")

fork(result, dir, cwd) = result
function fork(source::H.Tree, dir, cwd)
    try
        duplicate(new(dir, cwd), allpaths(source), Whole())
    finally
        close(source)
    end
end

abstract type CopyKind end
struct Whole <: CopyKind end
struct Path <: CopyKind end

function allpaths(tree::H.Tree)
    lock(tree.lock) do
        allpaths(tree, H.branches(tree))
    end
end
allpaths(tree, rejected::H.Rejected) = rejected
function allpaths(tree, branches::Vector)
    isempty(branches) && return H.Rejected(:invalid_record)
    allpaths(tree, branches[tree.leaf].state)
end
allpaths(tree, state::C.State) = allpaths(tree, state, H.ready(state))
allpaths(tree, state, rejected::H.Rejected) = rejected
allpaths(tree, state, ::Nothing) = allpaths(tree, pendinginput(state))
pendinginput(state::C.State) = isempty(state.steering) && isempty(state.followups) ? nothing : H.Rejected(:pending_inputs)
allpaths(tree, ::Nothing) = allpaths(tree, H.snapshot(tree.store))
function allpaths(tree, snapshot::H.Snapshot)
    snapshot.revision == tree.physical || return H.Rejected(:revision)
    snapshot.batches
end

function branchpath(tree::H.Tree, leaf::Integer)
    lock(tree.lock) do
        branchpath(tree, leaf, H.branches(tree))
    end
end
branchpath(tree, leaf, rejected::H.Rejected) = rejected
function branchpath(tree, leaf, branches::Vector)
    1 <= leaf <= length(branches) || return H.Rejected(:missing_branch)
    branchpath(tree, leaf, H.ready(branches[tree.leaf].state), H.ready(branches[leaf].state))
end
branchpath(tree, leaf, rejected::H.Rejected, target) = rejected
branchpath(tree, leaf, ::Nothing, rejected::H.Rejected) = rejected
branchpath(tree, leaf, ::Nothing, ::Nothing) = H.path(tree, leaf)

function queuedpath(tree::H.Tree, leaf::Integer)
    lock(tree.lock) do
        queuedpath(tree, leaf, H.branches(tree))
    end
end
queuedpath(tree, leaf, rejected::H.Rejected) = rejected
function queuedpath(tree, leaf, branches::Vector)
    1 <= leaf <= length(branches) || return H.Rejected(:missing_branch)
    queuedpath(tree, leaf, branches[leaf].state, H.ready(branches[tree.leaf].state))
end
queuedpath(tree, leaf, state, rejected::H.Rejected) = rejected
queuedpath(tree, leaf, state, ::Nothing) = queuedtarget(tree, leaf, state, queueable(state))
queueable(rejected::H.Rejected) = rejected
queueable(state::C.State) = queueable(state, state.phase)
queueable(state, ::C.Phase) = H.Rejected(:incomplete_turn)
queueable(state, ::Union{C.ReadyModelPhase, C.ReadyDecisionPhase}) = isempty(state.kernel.pending) ? nothing : H.Rejected(:uncertain_effect)
queuedtarget(tree, leaf, state, rejected::H.Rejected) = rejected
queuedtarget(tree, leaf, state::C.State, ::Nothing) = (; batches=H.path(tree, leaf), state)

append_event!(tree, state::C.State, event::K.Event) = append_event!(tree, event, K.step(state, event))
append_event!(tree, event::K.Event, rejected::K.Rejected) = H.Rejected(:invalid_record)
append_event!(tree, event::K.Event, applied::K.Applied) = append_event!(tree, applied.state, H.append!(tree, tree.leaf, Any[H.encode(event)]))
append_event!(tree, state::C.State, rejected::H.Rejected) = rejected
append_event!(tree, state::C.State, revision::Integer) = state

function prepare!(tree::H.Tree, state::C.State)
    result = nothing
    try
        result = prepare_interrupt!(tree, append_event!(tree, state, C.Dequeue(state.revision)))
    finally
        releasecopy!(tree, result)
    end
    result
end
prepare_interrupt!(tree, rejected::H.Rejected) = (close(tree); rejected)
prepare_interrupt!(tree, state::C.State) = prepared!(tree, append_event!(tree, state, C.Interrupt(state.revision, "fork")))
prepared!(tree, rejected::H.Rejected) = (close(tree); rejected)
prepared!(tree, state::C.State) = tree

memory(tree::H.Tree{<:H.Memory}) = tree.store
memory(tree::H.Tree{<:Deferred}) = tree.store.store
duplicate(tree, rejected::H.Rejected, mode::CopyKind) = (close(tree); rejected)
function duplicate(tree::H.Tree, batches::Vector, mode::CopyKind)
    result = nothing
    try
        result = duplicate(tree, mode, memory(tree), batches)
    finally
        releasecopy!(tree, result)
    end
    result
end
releasecopy!(tree, ::Union{H.Tree, H.Rejected}) = nothing
releasecopy!(tree, result) = close(tree)
function duplicate(tree, mode::CopyKind, store, batches::Vector)
    saved = foldl((revision, batch) -> appendbatch!(store, revision, batch), batches; init=0)
    duplicate(tree, mode, saved)
end
duplicate(tree, mode::CopyKind, rejected::H.Rejected) = (close(tree); rejected)
duplicate(tree, mode::CopyKind, saved::Integer) = duplicate(tree, mode, H.Tree(tree.store))
duplicate(tree, mode::CopyKind, result::H.Tree) = savecopy(result, mode)
savecopy(tree::H.Tree{<:H.Memory}, ::CopyKind) = tree
savecopy(tree::H.Tree{<:Deferred}, ::Whole) = savecopy(tree, H.snapshot(tree.store.store))
savecopy(tree::H.Tree{<:Deferred}, ::Path) = savecopy(tree, firstprompt(H.entries(tree)))
savecopy(tree, ::Nothing) = tree
savecopy(tree, prompt::String) = savecopy(tree, H.snapshot(tree.store.store))
savecopy(tree, rejected::H.Rejected) = (close(tree); rejected)
savecopy(tree, snapshot::H.Snapshot) = savecopy(tree, materialize!(tree.store, tree.store.store, snapshot))
savecopy(tree, revision::Integer) = tree

choose(::Recent, dir, cwd, input, output) = recent(list(dir, cwd), dir, cwd)
recent(items, dir, cwd) = isempty(items) ? new(dir, cwd) : openinfo(first(items))

function choose(request::Target, dir, cwd, input, output, redact=identity)
    path = expanduser(request.value)
    isfile(path) && return wrap(open(H.SQLite, path; create=false))
    matches = filter(item -> occursin(lowercase(request.value), item.id), list(dir, cwd))
    named(matches, request.value, redact)
end

function named(items, value, redact=identity)
    length(items) == 1 || return Invalid("No unique session found matching " * repr(redact(value)) * ".")
    openinfo(only(items))
end

function choose(::Picker, dir, cwd, input, output, redact=identity)
    items = list(dir, cwd)
    if isempty(items)
        println(output, "No sessions for this project.")
        return Cancelled()
    end
    for (index, item) in enumerate(items)
        title = strip(replace(redact(item.title), r"[\x00-\x1f\x7f]" => " "))
        println(output, "[", index, "] ", redact(item.id), "  ", first(title, min(length(title), 100)))
    end
    pick(items, input, output)
end

function pick(items, input, output)
    print(output, "Choose a session (number or q): ")
    flush(output)
    eof(input) && return Cancelled()
    value = strip(readline(input))
    value in ("", "q") && return Cancelled()
    pick(items, input, output, tryparse(Int, value))
end

function pick(items, input, output, ::Nothing)
    println(output, "Enter a session number or q.")
    pick(items, input, output)
end

function pick(items, input, output, index::Int)
    1 <= index <= length(items) && return openinfo(items[index])
    println(output, "Enter a session number or q.")
    pick(items, input, output)
end

end
