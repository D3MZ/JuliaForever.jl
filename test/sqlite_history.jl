using SQLite
import SQLite.DBInterface as DBI

@testset "SQLite history contract and connections" begin
    mktempdir() do dir
        path = joinpath(dir, "history π.sqlite")
        history = open(H.SQLite, path)
        @test history isa H.Store
        expected = exercise(H.Memory())
        @test isequal(exercise(history), expected)
        other = open(H.SQLite, path)
        @test history.status === :open
        @test isequal(collect(H.snapshot(other)), expected)
        @test H.append!(other, 2, Any["other connection"]) == 3
        @test H.append!(history, 2, Any["stale"]) == H.Rejected(:revision)
        close(history)
        @test history.status === :closed
        @test H.snapshot(history) == H.Rejected(:closed)
        @test H.append!(history, 3, Any["closed"]) == H.Rejected(:closed)
        close(history)
        close(other)
        reopened = open(H.SQLite, path)
        @test H.snapshot(reopened).revision == 3
        @test collect(H.snapshot(reopened))[end] == "other connection"
        close(reopened)
    end
    mktempdir() do dir
        path = joinpath(dir, "race.sqlite")
        histories = [open(H.SQLite, path) for _ in 1:4]
        race(histories)
        foreach(close, histories)
    end
end

@testset "SQLite competing processes" begin
    mktempdir() do dir
        path = joinpath(dir, "race.sqlite")
        gate = joinpath(dir, "go")
        script = """
            using SQLite, JuliaForever
            import JuliaForever.History as H
            history = open(H.SQLite, ARGS[1])
            println("ready")
            flush(stdout)
            while !isfile(ARGS[2])
                sleep(0.01)
            end
            result = H.append!(history, 0, Any[ARGS[3], Dict("writer" => ARGS[3])])
            println(result isa H.Rejected ? String(result.reason) : string(result))
            close(history)
        """
        project = dirname(Base.active_project())
        first = open(`$(Base.julia_cmd()) --project=$project -e $script $path $gate first`, "r")
        second = open(`$(Base.julia_cmd()) --project=$project -e $script $path $gate second`, "r")
        try
            @test readline(first) == "ready"
            @test readline(second) == "ready"
            write(gate, "go")
            @test sort([strip(read(first, String)), strip(read(second, String))]) == ["1", "revision"]
        finally
            close(first)
            close(second)
        end
        history = open(H.SQLite, path)
        snapshot = H.snapshot(history)
        rows = collect(snapshot)
        @test snapshot.revision == 1
        @test length(rows) == 2 && rows[1] == rows[2]["writer"]
        close(history)
    end
end

@testset "SQLite process death before and after commit" begin
    mktempdir() do dir
        path = joinpath(dir, "crash.sqlite")
        history = open(H.SQLite, path)
        @test H.append!(history, 0, Any["first"]) == 1
        close(history)
        project = dirname(Base.active_project())
        uncommitted = """
            using SQLite
            db = SQLite.DB(ARGS[1])
            SQLite.execute(db, "BEGIN IMMEDIATE")
            SQLite.execute(db, "INSERT INTO jf_history VALUES (?, ?)", (2, "[\\\"not committed\\\"]"))
            println("inserted")
            flush(stdout)
            sleep(300)
        """
        process = open(`$(Base.julia_cmd()) --project=$project -e $uncommitted $path`, "r")
        try
            @test readline(process) == "inserted"
        finally
            kill(process, Base.SIGKILL)
            wait(process)
            close(process)
        end
        history = open(H.SQLite, path)
        @test H.snapshot(history).revision == 1
        @test collect(H.snapshot(history)) == Any["first"]
        close(history)
        committed = """
            using SQLite, JuliaForever
            import JuliaForever.History as H
            history = open(H.SQLite, ARGS[1])
            H.append!(history, 1, Any["committed"]) == 2 || exit(3)
            println("committed")
            flush(stdout)
            sleep(300)
        """
        process = open(`$(Base.julia_cmd()) --project=$project -e $committed $path`, "r")
        try
            @test readline(process) == "committed"
        finally
            kill(process, Base.SIGKILL)
            wait(process)
            close(process)
        end
        history = open(H.SQLite, path)
        @test H.snapshot(history).revision == 2
        @test collect(H.snapshot(history)) == Any["first", "committed"]
        close(history)
    end
end

@testset "SQLite existing-only open preserves invalid files" begin
    mktempdir() do dir
        missing = joinpath(dir, "missing.sqlite")
        @test open(H.SQLite, missing; create=false) == H.Rejected(:history_missing)
        @test !ispath(missing)

        empty = joinpath(dir, "empty.sqlite")
        db = SQLite.DB(empty)
        SQLite.execute(db, "PRAGMA user_version = 1")
        close(db)
        before = read(empty)
        @test open(H.SQLite, empty; create=false) == H.Rejected(:history_format)
        @test read(empty) == before

        history = open(H.SQLite, empty)
        @test history isa H.SQLite
        @test H.append!(history, 0, Any["saved"]) == 1
        close(history)
        reopened = open(H.SQLite, empty; create=false)
        @test reopened isa H.SQLite
        @test collect(H.snapshot(reopened)) == Any["saved"]
        close(reopened)
    end
end

@testset "SQLite rejects an unrelated database" begin
    mktempdir() do dir
        path = joinpath(dir, "other.sqlite")
        db = SQLite.DB(path)
        SQLite.execute(db, "CREATE TABLE unrelated (value TEXT)")
        close(db)
        @test open(H.SQLite, path) == H.Rejected(:history_format)
        db = SQLite.DB(path)
        @test [row.name for row in DBI.execute(db, "SELECT name FROM sqlite_master WHERE type = 'table'")] == ["unrelated"]
        close(db)
    end
    mktempdir() do dir
        path = joinpath(dir, "other.sqlite")
        db = SQLite.DB(path)
        SQLite.execute(db, "CREATE TABLE sqliteX (value TEXT)")
        close(db)
        @test open(H.SQLite, path) == H.Rejected(:history_format)
        db = SQLite.DB(path)
        @test [row.name for row in DBI.execute(db, "SELECT name FROM sqlite_master WHERE type = 'table'")] == ["sqliteX"]
        close(db)
    end
end

@testset "SQLite failed commit requires reopen" begin
    mktempdir() do dir
        path = joinpath(dir, "failure.sqlite")
        history = open(H.SQLite, path)
        @test H.append!(history, 0, Any["first"]) == 1
        db = history.db
        SQLite.execute(db, "PRAGMA foreign_keys = ON")
        SQLite.execute(db, "CREATE TEMP TABLE parent (id INTEGER PRIMARY KEY)")
        SQLite.execute(db, "CREATE TEMP TABLE child (id INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED)")
        SQLite.execute(db, "CREATE TEMP TRIGGER failcommit AFTER INSERT ON main.jf_history BEGIN INSERT INTO child VALUES (42); END")
        @test_throws SQLite.SQLiteException H.append!(history, 1, Any["second"])
        @test history.status === :uncertain
        @test H.snapshot(history) == H.Rejected(:uncertain)
        @test H.append!(history, 1, Any["retry"]) == H.Rejected(:uncertain)
        close(history)
        history = open(H.SQLite, path)
        @test H.snapshot(history).revision == 1
        @test collect(H.snapshot(history)) == Any["first"]
        @test H.append!(history, 1, Any["after recovery"]) == 2
        close(history)
    end
end

@testset "SQLite passive agent replay" begin
    mktempdir() do dir
        path = joinpath(dir, "agent.sqlite")
        call = Dict{String, Any}("id" => "one", "type" => "function", "function" => Dict("name" => "write", "arguments" => "{\"path\":\"a.txt\",\"content\":\"safe\"}"))
        provider = Scripted([Dict{String, Any}("role" => "assistant", "content" => nothing, "tool_calls" => [call]), Dict("role" => "assistant", "content" => "done")], [])
        history = open(H.SQLite, path)
        agent = Agent(provider, [Write(dir)]; history)
        @test respond!(agent, "start") == "done"
        @test read(joinpath(dir, "a.txt"), String) == "safe"
        revision = agent.state.revision
        close(history)
        rm(joinpath(dir, "a.txt"))
        history = open(H.SQLite, path)
        restored = Agent(provider, [Write(dir)]; history)
        @test restored.state.phase == C.Complete
        @test restored.state.revision == revision
        @test length(provider.requests) == 2
        @test !isfile(joinpath(dir, "a.txt"))
        close(history)
    end
end

@testset "SQLite interrupted agent requires an explicit decision" begin
    mktempdir() do dir
        path = joinpath(dir, "agent.sqlite")
        marker = joinpath(dir, "effect.txt")
        script = """
            using SQLite, JuliaForever
            import JuliaForever.History as H
            struct Provider end
            function JuliaForever.complete(::Provider, messages, tools)
                call = Dict{String, Any}("id" => "one", "type" => "function", "function" => Dict("name" => "die", "arguments" => "{}"))
                Dict{String, Any}("role" => "assistant", "content" => nothing, "tool_calls" => [call])
            end
            struct Die <: JuliaForever.Tool
                marker::String
            end
            JuliaForever.name(::Die) = "die"
            function JuliaForever.execute(tool::Die, args)
                write(tool.marker, "effect ran")
                exit(17)
            end
            history = open(H.SQLite, ARGS[1])
            agent = Agent(Provider(), [Die(ARGS[2])]; history)
            respond!(agent, "start")
            exit(19)
        """
        project = dirname(Base.active_project())
        process = run(ignorestatus(`$(Base.julia_cmd()) --project=$project -e $script $path $marker`))
        @test process.exitcode == 17
        @test read(marker, String) == "effect ran"
        provider = Scripted([], [])
        history = open(H.SQLite, path)
        restored = Agent(provider, []; history)
        @test restored.state.phase == C.WaitingTools
        @test respond!(restored, "next") == H.Rejected(:uncertain_effect)
        @test isempty(provider.requests)
        @test JuliaForever.abandon!(restored, "effect inspected") isa K.Applied
        close(history)
        history = open(H.SQLite, path)
        restored = Agent(provider, []; history)
        @test restored.state.phase == C.Incomplete
        @test isempty(provider.requests)
        @test read(marker, String) == "effect ran"
        close(history)
    end
end
