module SQLiteHistory

using SQLite, JSON3
import SQLite.DBInterface as DBI
import ..History as H
import Base: append!

const format = "JuliaForever.History.SQLite/1"

function schema(db)
    DBI.execute(db, "SELECT name FROM sqlite_master WHERE type IN ('table', 'view', 'trigger') AND name NOT GLOB 'sqlite_*' ORDER BY name") do rows
        [row.name for row in rows]
    end
end

function initialize(db; create=true)
    SQLite.execute(db, create ? "BEGIN IMMEDIATE" : "BEGIN")
    names = schema(db)
    if isempty(names)
        if !create
            SQLite.execute(db, "ROLLBACK")
            return H.Rejected(:history_format)
        end
        SQLite.execute(db, "CREATE TABLE jf_meta (format TEXT NOT NULL)")
        SQLite.execute(db, "INSERT INTO jf_meta VALUES (?)", (format,))
        SQLite.execute(db, "CREATE TABLE jf_history (revision INTEGER PRIMARY KEY, data TEXT NOT NULL)")
    elseif names != ["jf_history", "jf_meta"]
        SQLite.execute(db, "ROLLBACK")
        return H.Rejected(:history_format)
    else
        markers = DBI.execute(db, "SELECT format FROM jf_meta") do rows
            [row.format for row in rows]
        end
        if markers != [format]
            SQLite.execute(db, "ROLLBACK")
            return H.Rejected(:history_format)
        end
    end
    SQLite.execute(db, "COMMIT")
    nothing
end

openhistory(db, rejected::H.Rejected) = rejected
openhistory(db, ::Nothing) = H.SQLite(db, ReentrantLock(), H.Open())
closefailed!(db, ::H.SQLite) = nothing
closefailed!(db, result) = close(db)

function Base.open(::Type{H.SQLite}, path::AbstractString; create=true)
    path = expanduser(path)
    if !create
        isfile(path) || return H.Rejected(:history_missing)
        header = open(path, "r") do file
            read(file, 16)
        end
        header == codeunits("SQLite format 3\0") || return H.Rejected(:history_format)
    end
    db = SQLite.DB(path)
    opened = nothing
    try
        SQLite.busy_timeout(db, 5000)
        mode = DBI.execute(db, "PRAGMA journal_mode") do rows
            only([row.journal_mode for row in rows])
        end
        mode in ("delete", "truncate", "persist", "wal") || return H.Rejected(:history_format)
        SQLite.execute(db, "PRAGMA synchronous = EXTRA")
        opened = openhistory(db, initialize(db; create))
    finally
        closefailed!(db, opened)
    end
end

function Base.close(history::H.SQLite{SQLite.DB})
    lock(history.lock) do
        close(history, getfield(history, :status))
    end
end

Base.close(history::H.SQLite{SQLite.DB}, ::H.Closed) = nothing

function Base.close(history::H.SQLite{SQLite.DB}, status::H.SQLiteStatus)
    setfield!(history, :status, H.Closed())
    close(history.db)
    nothing
end

H.Rejected(::H.Closed) = H.Rejected(:closed)
H.Rejected(::H.Uncertain) = H.Rejected(:uncertain)

function H.snapshot(history::H.SQLite{SQLite.DB})
    lock(history.lock) do
        H.snapshot(history, getfield(history, :status))
    end
end

H.snapshot(history::H.SQLite{SQLite.DB}, status::H.SQLiteStatus) = H.Rejected(status)

formaterror(exception) = false
formaterror(::ArgumentError) = true
rawbatch(data) = H.Rejected(:history_format)

function rawbatch(data::AbstractString)
    depth = length(current_exceptions())
    try
        JSON3.read(codeunits(data), Vector{Any})
    finally
        exceptions = current_exceptions()
        if length(exceptions) > depth && formaterror(last(exceptions).exception)
            return H.Rejected(:history_format)
        end
    end
end

readrow(rejected::H.Rejected, row) = rejected
validrevision(value, expected) = false
validrevision(value::Integer, expected) = value == expected

function readrow(batches::Vector{Vector{Any}}, row)
    validrevision(row.revision, length(batches) + 1) || return H.Rejected(:history_format)
    readrow(batches, rawbatch(row.data))
end

readrow(batches::Vector{Vector{Any}}, rejected::H.Rejected) = rejected

function readrow(batches::Vector{Vector{Any}}, batch::Vector)
    H.addbatch!(batches, H.decodebatch(batch))
end

snapshot(rejected::H.Rejected) = rejected
snapshot(batches::Vector{Vector{Any}}) = H.Snapshot(length(batches), batches)

function H.snapshot(history::H.SQLite{SQLite.DB}, ::H.Open)
    DBI.execute(history.db, "SELECT revision, data FROM jf_history ORDER BY revision") do rows
        snapshot(foldl(readrow, rows; init=Vector{Any}[]))
    end
end

function append!(history::H.SQLite{SQLite.DB}, revision::Integer, batch::Vector)
    lock(history.lock) do
        append!(history, revision, batch, getfield(history, :status))
    end
end

append!(history::H.SQLite{SQLite.DB}, revision::Integer, batch::Vector, status::H.SQLiteStatus) = H.Rejected(status)
transaction(::H.Rejected) = "ROLLBACK"
transaction(::Integer) = "COMMIT"
write!(db, revision, rejected::H.Rejected) = rejected

function write!(db, revision, saved::Vector)
    data = JSON3.write(Any[H.encode(item) for item in saved])
    SQLite.execute(db, "INSERT INTO jf_history (revision, data) VALUES (?, ?)", (revision + 1, data))
    revision + 1
end

function append!(history::H.SQLite{SQLite.DB}, revision::Integer, batch::Vector, ::H.Open)
    db = history.db
    committed = nothing
    try
        SQLite.execute(db, "BEGIN IMMEDIATE")
        current = DBI.execute(db, "SELECT COALESCE(MAX(revision), 0) AS revision FROM jf_history") do rows
            only([row.revision for row in rows])
        end
        result = if current != revision
            H.Rejected(:revision)
        elseif isempty(batch)
            H.Rejected(:empty_batch)
        else
            write!(db, current, H.value(batch, IdDict()))
        end
        SQLite.execute(db, transaction(result))
        committed = Some(result)
        result
    finally
        uncertain!(history, committed)
    end
end

uncertain!(history, ::Some) = nothing
uncertain!(history, ::Nothing) = setfield!(history, :status, H.Uncertain())

end
