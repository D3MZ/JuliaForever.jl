using SQLite
import ..SQLiteHistory as SH

abstract type SQLStatus end
struct SQLOk <: SQLStatus end
struct SQLRow <: SQLStatus end
struct SQLDone <: SQLStatus end
struct SQLFailure <: SQLStatus end
const sqlstatuses = Dict(SQLite.C.SQLITE_OK => SQLOk(), SQLite.C.SQLITE_ROW => SQLRow(), SQLite.C.SQLITE_DONE => SQLDone())
sqlstatus(code) = get(sqlstatuses, code, SQLFailure())

function readonly(f, path)
    handle = Ref{SQLite.DBHandle}(C_NULL)
    code = SQLite.C.sqlite3_open_v2(path, handle, SQLite.C.SQLITE_OPEN_READONLY, C_NULL)
    try
        readonly(f, handle[], sqlstatus(code))
    finally
        SQLite.C.sqlite3_close_v2(handle[])
    end
end
readonly(f, handle, ::SQLStatus) = nothing
function readonly(f, handle, ::SQLOk)
    code = SQLite.C.sqlite3_exec(handle, "BEGIN", C_NULL, C_NULL, C_NULL)
    readtransaction(f, handle, sqlstatus(code))
end
readtransaction(f, handle, ::SQLStatus) = nothing
readtransaction(f, handle, ::SQLOk) = f(handle)

const historyquery = "SELECT revision, data FROM jf_history WHERE (SELECT group_concat(name, ',') FROM (SELECT name FROM sqlite_master WHERE type IN ('table', 'view', 'trigger') AND name NOT GLOB 'sqlite_*' ORDER BY name)) = 'jf_history,jf_meta' AND (SELECT count(*) FROM jf_meta) = 1 AND (SELECT format FROM jf_meta LIMIT 1) = 'JuliaForever.History.SQLite/1' ORDER BY revision"
function historyrows(handle, sql)
    statement = Ref{SQLite.StmtHandle}(C_NULL)
    code = SQLite.C.sqlite3_prepare_v2(handle, sql, -1, statement, C_NULL)
    try
        historyrows(statement[], sqlstatus(code))
    finally
        SQLite.C.sqlite3_finalize(statement[])
    end
end
historyrows(statement, ::SQLStatus) = H.Rejected(:history_format)
historyrows(statement, ::SQLOk) = SH.snapshot(foldl(appendrow, SQLRows(statement); init=Vector{Any}[]))
struct SQLRows
    statement::SQLite.StmtHandle
end
Base.IteratorSize(::Type{SQLRows}) = Base.SizeUnknown()
Base.IteratorEltype(::Type{SQLRows}) = Base.EltypeUnknown()
Base.iterate(rows::SQLRows) = sqlrow(rows, sqlstatus(SQLite.C.sqlite3_step(rows.statement)))
Base.iterate(rows::SQLRows, ::Nothing) = iterate(rows)
Base.iterate(rows::SQLRows, ::SQLDone) = nothing
sqlrow(rows, ::SQLStatus) = (H.Rejected(:history_format), SQLDone())
sqlrow(rows, ::SQLDone) = nothing
sqlrow(rows, ::SQLRow) = ((; revision=sqlinteger(rows.statement), data=sqltext(rows.statement)), nothing)
appendrow(batches, rejected::H.Rejected) = rejected
appendrow(batches, row) = SH.readrow(batches, row)
abstract type SQLType end
struct SQLInteger <: SQLType end
struct SQLText <: SQLType end
struct SQLOther <: SQLType end
const sqltypes = Dict(SQLite.C.SQLITE_INTEGER => SQLInteger(), SQLite.C.SQLITE_TEXT => SQLText())
sqltype(code) = get(sqltypes, code, SQLOther())
sqlinteger(statement) = sqlinteger(statement, sqltype(SQLite.C.sqlite3_column_type(statement, 0)))
sqlinteger(statement, ::SQLType) = nothing
sqlinteger(statement, ::SQLInteger) = SQLite.C.sqlite3_column_int64(statement, 0)
sqltext(statement) = sqltext(statement, sqltype(SQLite.C.sqlite3_column_type(statement, 1)))
sqltext(statement, ::SQLType) = nothing
sqltext(statement, ::SQLText) = sqlbytes(SQLite.C.sqlite3_column_text(statement, 1), SQLite.C.sqlite3_column_bytes(statement, 1))
sqlbytes(pointer, length) = pointer == C_NULL ? nothing : unsafe_string(pointer, length)

caseinitial(value) = nothing
caseinitial(snapshot::H.Snapshot) = caseinitial(snapshot.batches)
caseinitial(batches::Vector{Vector{Any}}) = isempty(batches) ? nothing : caseinitial(H.treenode(first(batches), 0))
caseinitial(node::H.TreeNode) = H.firststate(node.batch)
casecwd(value) = nothing
casecwd(state::C.State) = casecwd(first(state.messages, 1))
casecwd(messages::AbstractVector) = isempty(messages) ? nothing : casecwd(first(messages))
abstract type InitialRole end
struct InitialSystem <: InitialRole end
struct OtherInitial <: InitialRole end
const initialroles = Dict("system" => InitialSystem())
casecwd(message::C.RawMessage) = casecwd(get(initialroles, get(message.value, "role", nothing), OtherInitial()), get(message.value, "content", nothing))
casecwd(role, content) = nothing
function casecwd(::InitialSystem, content::AbstractString)
    sections = split(content, "\n\n"; limit=3)
    length(sections) == 3 || return nothing
    startswith(sections[2], "Working directory: ") || return nothing
    String(chopprefix(sections[2], "Working directory: "))
end

function casecandidate(path, id, prefix, paths, forms)
    readonly(path) do db
        initial = historyrows(db, historyquery * " LIMIT 1")
        casecandidate(db, path, id, prefix, paths, forms, catalogcwd(db, caseinitial(initial)))
    end
end
catalogcwd(db, value) = nothing
catalogcwd(db, state::C.State) = readcwd(db, casecwd(state))
function readcwd(db, fallback)
    statement = Ref{SQLite.StmtHandle}(C_NULL)
    code = SQLite.C.sqlite3_prepare_v2(db, "SELECT 0, cwd FROM jf_meta", -1, statement, C_NULL)
    try
        readcwd(statement[], sqlstatus(code), fallback)
    finally
        SQLite.C.sqlite3_finalize(statement[])
    end
end
readcwd(statement, ::SQLStatus, fallback) = fallback
readcwd(statement, ::SQLOk, fallback) = readcwd(statement, sqlstatus(SQLite.C.sqlite3_step(statement)), fallback)
readcwd(statement, ::SQLRow, fallback) = recordedcwd(sqltext(statement), fallback)
recordedcwd(::Nothing, fallback) = fallback
recordedcwd(cwd::String, fallback) = cwd
casecandidate(db, path, id, prefix, paths, forms, recorded) = nothing
function casecandidate(db, path, id, prefix, paths, forms, recorded::String)
    directory = abspath(recorded)
    project(directory) == prefix || return nothing
    any(form -> caseequal(caseform(directory), form), forms) || return nothing
    sameproject(first(paths), directory) || return nothing
    caseinfo(path, id, historyrows(db, historyquery))
end
pathfailures(exceptions, depth) = length(exceptions) > depth ? pathfailures(last(exceptions).exception) : ()
pathfailures(::Base.IOError) = (false,)
pathfailures(exception) = ()
function sameproject(a, b)
    depth = length(current_exceptions())
    try
        samefile(a, b)
    finally
        for failure in pathfailures(current_exceptions(), depth)
            return failure
        end
    end
end
caseinfo(path, id, rejected::H.Rejected) = info(path, id, rejected)
function caseinfo(path, id, snapshot::H.Snapshot)
    store = H.Memory(ReentrantLock(), snapshot.batches)
    info(path, id, H.Tree(store))
end

const sessionfile = r"^([0-9a-f]{24})--([0-9a-f]{32})\.sqlite$"
casefile!(items, dir, file, ::Nothing, paths, forms, direct) = items
function casefile!(items, dir, file, found::RegexMatch, paths, forms, direct)
    prefix, id = String(found.captures[1]), String(found.captures[2])
    prefix in direct || pushinfo!(items, casecandidate(joinpath(dir, file), id, prefix, paths, forms))
    items
end

function listcase(dir, paths)
    items = list(dir, projectpattern(paths))
    isdir(dir) || return items
    forms = caseform.(paths)
    direct = Set(project.(paths))
    for file in readdir(dir)
        casefile!(items, dir, file, match(sessionfile, file), paths, forms, direct)
    end
    sort!(items; by=item -> (item.modified, item.path), rev=true)
end
