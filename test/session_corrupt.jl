using Test, JuliaForever, SQLite, JSON3
import JuliaForever.History as CorruptHistory
import JuliaForever.SessionCatalog as CorruptCatalog
import JuliaForever.Durable as CorruptDurable

struct UnexpectedHistoryText <: AbstractString end
Base.codeunits(::UnexpectedHistoryText) = error("unexpected decoding failure")
Base.ncodeunits(::UnexpectedHistoryText) = error("unexpected decoding failure")

@testset "corrupt session rows are rejected without disclosure" begin
    @test_throws ErrorException JuliaForever.SQLiteHistory.rawbatch(UnexpectedHistoryText())
    mktempdir() do root
        key = "synthetic-corrupt-key"
        workspace = joinpath(root, "workspace")
        sessions = joinpath(root, "sessions")
        mkpath(workspace)
        for (index, data) in enumerate(("[{\"fixture\":\"$key\"}", "[{\"fixture\":\"$key\"}]", "[[3,\"$key\"]]"))
            path = joinpath(root, "history-$index.sqlite")
            history = open(CorruptHistory.SQLite, path)
            SQLite.DBInterface.execute(history.db, "INSERT INTO jf_history (revision, data) VALUES (?, ?)", (1, data))
            @test CorruptHistory.snapshot(history) == CorruptHistory.Rejected(:history_format)
            result = try
                CorruptCatalog.adapt(history)
            catch exception
                exception
            end
            @test result == CorruptHistory.Rejected(:history_format)
            @test getfield(history, :status) isa CorruptHistory.Closed
            close(history)

            requests = joinpath(root, "requests-$index")
            output, diagnostics = joinpath.((root,), ("stdout-$index", "stderr-$index"))
            project = dirname(@__DIR__)
            script = joinpath(@__DIR__, "session_cli_process.jl")
            cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project $script --history $path prompt`; dir=workspace)
            cmd = addenv(cmd, "JF_SESSION_REQUESTS" => requests, "JF_SESSION_DIR" => sessions, "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => key, "JF_INSTRUCTIONS_DIR" => nothing)
            process = run(pipeline(ignorestatus(cmd); stdin=devnull, stdout=output, stderr=diagnostics))
            text = read(diagnostics, String)
            @test process.exitcode == 1 && occursin("history_format", text)
            @test !occursin(key, text) && !occursin(key, read(output, String))
            @test !isfile(requests)
        end
        malformed = Any[
            Any[Any[]], Any[Any[3]], Any[Any[9, key]], Any[Any[0, key]],
            Any[Any[1, Any[]]], Any[Any[2, key]], Any[Any[1, Dict("nested" => Any[3, key])]],
            Any[Any[0, Any[Any[]]]], Any[Any[3, key, "extra"]],
        ]
        for (index, batch) in enumerate(malformed)
            path = joinpath(root, "shape-$index.sqlite")
            history = open(CorruptHistory.SQLite, path)
            SQLite.DBInterface.execute(history.db, "INSERT INTO jf_history (revision, data) VALUES (?, ?)", (1, JSON3.write(batch)))
            @test CorruptHistory.snapshot(history) == CorruptHistory.Rejected(:history_format)
            close(history)
        end
    end
end

@testset "history encodings reject malformed Journal data" begin
    if Sys.isunix()
    mktempdir() do root
        store = open(CorruptDurable.Store, joinpath(root, "journal.jsonl"))
        try
            journal = CorruptHistory.create(store)
            values = Any[nothing, true, 42, -0.0, 1.5, "π😀", Any[1, Dict("nested" => "value")]]
            @test CorruptHistory.append!(journal, 0, values) == 1
            @test isequal(collect(CorruptHistory.snapshot(journal)), values)
            for value in values
                @test isequal(CorruptHistory.decode(CorruptHistory.encode(value)), value)
            end
            record = get(store, CorruptDurable.Document, journal.id)
            key = "synthetic-journal-key"
            bad = Any[Any[], Any[3], Any[9, key], Any[0, key], Any[1, Any[]], Any[2, key], Any[1, Dict("nested" => Any[3, key])], Any[0, Any[Any[]]], Any[3, key, "extra"]]
            for value in bad
                data = Dict("format" => "JuliaForever.History/1", "revision" => 1, "batches" => Any[Any[value]])
                committed = CorruptDurable.commit!(store) do tx
                    CorruptDurable.put!(tx, CorruptDurable.Document(record.id, record.conversation, data))
                end
                @test committed isa Integer
                @test CorruptHistory.snapshot(journal) == CorruptHistory.Rejected(:history_format)
            end
            data = Dict("format" => "JuliaForever.History/1", "revision" => 2, "batches" => Any[Any["record"]])
            CorruptDurable.commit!(store) do tx
                CorruptDurable.put!(tx, CorruptDurable.Document(record.id, record.conversation, data))
            end
            @test CorruptHistory.snapshot(journal) == CorruptHistory.Rejected(:history_format)
        finally
            close(store)
        end
    end
    else
        @test_skip "Journal storage requires Unix"
    end
end

@testset "corrupt session discovery does not expose credentials" begin
    for mode in (:syntax, :tag)
        mktempdir() do root
            key = "sk-synthetic-" * repeat("x", 48)
            workspace, sessions = joinpath(root, "workspace"), joinpath(root, "sessions")
            mkpath.((workspace, sessions))
            workspace = cd(pwd, workspace)
            path = joinpath(sessions, CorruptCatalog.filename(workspace, repeat("a", 32)))
            history = open(CorruptHistory.SQLite, path)
            data = mode == :syntax ? "[{\"fixture\":\"$key\"}" : JSON3.write([[3, key]])
            SQLite.DBInterface.execute(history.db, "INSERT INTO jf_history (revision, data) VALUES (?, ?)", (1, data))
            close(history)
            project = dirname(@__DIR__)
            script = joinpath(@__DIR__, "session_cli_process.jl")
            for (route, args, input, expected) in ((:history, ["--history", path, "prompt"], "", 1), (:session, ["--session", path, "prompt"], "", 1), (:continue, ["--continue", "prompt"], "", 1), (:resume_start, ["--resume"], "q\n", 0), (:resume_interactive, ["--no-session"], "/resume\nq\n/exit\n", 0), (:resume_select, ["--resume"], "1\n", 1), (:interactive_select, ["--no-session"], "/resume\n1\n/exit\n", 1))
                requests = joinpath(root, "requests-$route")
                stdout, stderr, stdin = joinpath.((root,), ("stdout-$route", "stderr-$route", "stdin-$route"))
                write(stdin, input)
                cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project $script $args`; dir=workspace)
                cmd = addenv(cmd, "JF_SESSION_REQUESTS" => requests, "JF_SESSION_DIR" => sessions, "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => key, "JF_INSTRUCTIONS_DIR" => nothing)
                process = run(pipeline(ignorestatus(cmd); stdin, stdout, stderr))
                @test process.exitcode == expected
                @test !occursin(key, read(stderr, String)) && !occursin(key, read(stdout, String))
                @test !isfile(requests)
            end
        end
    end
end
