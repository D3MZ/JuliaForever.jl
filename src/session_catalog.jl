module SessionCatalog

using Random, SHA
import ..History as H
import ..Conversation as C
import Base: append!

abstract type Request end
struct New <: Request end
struct Recent <: Request end
struct Picker <: Request end
struct Ephemeral <: Request end
struct Target <: Request
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
append!(history::Deferred, store::H.Memory, revision, batch) = materialize!(history, revision, append!(store, revision, batch))
materialize!(history, revision::Integer, rejected::H.Rejected) = rejected

function materialize!(history, revision::Integer, saved::Integer)
    revision == 0 && return saved
    mkpath(dirname(history.path))
    file = Base.Filesystem.open(history.path, Base.JL_O_WRONLY | Base.JL_O_CREAT | Base.JL_O_EXCL, 0o600)
    close(file)
    materialize!(history, open(H.SQLite, history.path), H.snapshot(history.store))
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
firstprompt(::Nothing, event::C.Input) = event.text
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

info(path, id, ::Nothing) = nothing
function modified(path)
    time = stat(path).mtime
    wal = path * "-wal"
    isfile(wal) ? max(time, stat(wal).mtime) : time
end

info(path, id, title::String) = Info(path, id, title, modified(path))
info(path, id, ::H.Rejected) = nothing
info(path, id, snapshot::H.Snapshot) = info(path, id, firstprompt(snapshot))
info(path, id, tree::H.Tree) = info(path, id, firstprompt(H.entries(tree)))

function info(path, id, store::H.SQLite)
    try
        info(path, id, H.Tree(store))
    finally
        close(store)
    end
end

pushinfo!(items, ::Nothing) = items
pushinfo!(items, item::Info) = (push!(items, item); items)

function list(dir, cwd)
    isdir(dir) || return Info[]
    pattern = Regex("^" * project(cwd) * raw"--([0-9a-f]{32})\.sqlite$")
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
wrap(store::H.SQLite) = wrap(store, H.Tree(store))
wrap(store::H.SQLite, tree::H.Tree) = tree
wrap(store::H.SQLite, rejected::H.Rejected) = (close(store); rejected)

istree(record) = false
istree(record::Dict) = get(record, "format", "") == H.treeformat
istree(batch::Vector) = any(istree, batch)

adapt(rejected::H.Rejected) = rejected
adapt(store::H.SQLite) = adapt(store, H.snapshot(store))
adapt(store::H.SQLite, rejected::H.Rejected) = (close(store); rejected)
adapt(store::H.SQLite, snapshot::H.Snapshot) = any(istree, snapshot.batches) ? wrap(store) : store

openinfo(info::Info) = wrap(open(H.SQLite, info.path; create=false))
choose(request::Request, dir, cwd, input, output, redact) = choose(request, dir, cwd, input, output)
choose(::New, dir, cwd, input, output) = new(dir, cwd)
choose(::Ephemeral, dir, cwd, input, output) = H.Tree(H.Memory())
choose(request::Explicit, dir, cwd, input, output) = adapt(open(H.SQLite, request.path))
choose(::Conflict, dir, cwd, input, output) = Invalid("Choose only one session option.")

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
