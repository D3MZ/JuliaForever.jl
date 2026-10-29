module SQLiteExt

using SQLite, JSON3
import SQLite.DBInterface as DBI
import JuliaForever.History as H
import Base: append!

const format = "JuliaForever.History.SQLite/1"

function schema(db)
    DBI.execute(db, "SELECT name FROM sqlite_master WHERE type IN ('table', 'view', 'trigger') AND name NOT GLOB 'sqlite_*' ORDER BY name") do rows
        [row.name for row in rows]
    end
end

function initialize(db)
    SQLite.execute(db, "BEGIN IMMEDIATE")
    names = schema(db)
    if isempty(names)
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

function Base.open(::Type{H.SQLite}, path::AbstractString)
    db = SQLite.DB(path)
    opened = false
    try
        SQLite.busy_timeout(db, 5000)
        mode = DBI.execute(db, "PRAGMA journal_mode") do rows
            only([row.journal_mode for row in rows])
        end
        mode in ("delete", "truncate", "persist", "wal") || return H.Rejected(:history_format)
        SQLite.execute(db, "PRAGMA synchronous = EXTRA")
        result = initialize(db)
        result isa H.Rejected && return result
        opened = true
        H.SQLite(db, ReentrantLock(), :open)
    finally
        opened || close(db)
    end
end

function Base.close(history::H.SQLite{SQLite.DB})
    lock(history.lock) do
        history.status === :closed && return nothing
        history.status = :closed
        close(history.db)
        nothing
    end
end

function H.snapshot(history::H.SQLite{SQLite.DB})
    lock(history.lock) do
        history.status === :open || return H.Rejected(history.status)
        DBI.execute(history.db, "SELECT revision, data FROM jf_history ORDER BY revision") do rows
            batches = Vector{Any}[]
            for row in rows
                row.revision == length(batches) + 1 || return H.Rejected(:history_format)
                batch = JSON3.read(row.data, Vector{Any})
                push!(batches, Any[H.decode(item) for item in batch])
            end
            H.Snapshot(length(batches), batches)
        end
    end
end

function append!(history::H.SQLite{SQLite.DB}, revision::Integer, batch::Vector)
    lock(history.lock) do
        history.status === :open || return H.Rejected(history.status)
        db = history.db
        complete = false
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
                saved = H.value(batch, IdDict())
                if saved isa H.Rejected
                    saved
                else
                    data = JSON3.write(Any[H.encode(item) for item in saved])
                    SQLite.execute(db, "INSERT INTO jf_history (revision, data) VALUES (?, ?)", (current + 1, data))
                    current + 1
                end
            end
            SQLite.execute(db, result isa H.Rejected ? "ROLLBACK" : "COMMIT")
            complete = true
            result
        finally
            complete || (history.status = :uncertain)
        end
    end
end

end
