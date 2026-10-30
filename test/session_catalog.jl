using Test, JuliaForever, SQLite
import JuliaForever.History as H
import JuliaForever.SessionCatalog as Catalog

@testset "deferred session history" begin
    mktempdir() do root
        path = joinpath(root, "nested", "session.sqlite")
        session = Catalog.Deferred(path)
        @test H.append!(session, 0, Any["initial"]) == 1
        @test !ispath(dirname(path))
        @test H.append!(session, 0, Any["stale"]) == H.Rejected(:revision)
        @test !isfile(path)
        @test H.append!(session, 1, Any["first event"]) == 2
        @test isfile(path)
        @test H.snapshot(session).batches == [Any["initial"], Any["first event"]]
        @test H.append!(session, 2, Any["second event"]) == 3
        close(session)
        reopened = open(H.SQLite, path; create=false)
        @test H.snapshot(reopened).batches == [Any["initial"], Any["first event"], Any["second event"]]
        close(reopened)

        collision = joinpath(root, "existing.sqlite")
        write(collision, "keep existing file")
        session = Catalog.Deferred(collision)
        @test H.append!(session, 0, Any["initial"]) == 1
        @test_throws Exception H.append!(session, 1, Any["event"])
        @test read(collision, String) == "keep existing file"
        close(session)
    end
end

@testset "session discovery and WAL activity" begin
    mktempdir() do root
        cwd = joinpath(root, "project")
        mkpath(cwd)
        session = Catalog.new(root, cwd)
        initial = JuliaForever.Conversation.State("test"; automatic=false)
        @test H.append!(session, 0, Any[H.encode_initial(initial)]) == 1
        @test H.append!(session, 1, Any[H.encode(JuliaForever.Conversation.Input(0, "first prompt"))]) == 2
        SQLite.execute(session.store.db, "PRAGMA journal_mode=WAL")
        @test H.append!(session, 2, Any[H.encode(JuliaForever.Conversation.Input(1, "more"))]) == 3
        wal = session.path * "-wal"
        @test isfile(wal)
        info = only(Catalog.list(root, cwd))
        @test info.title == "first prompt"
        @test info.modified == max(stat(session.path).mtime, stat(wal).mtime)
        @test isempty(Catalog.list(root, joinpath(root, "other")))
        close(session)
    end
end

@testset "session target redacts only the diagnostic" begin
    for key in ("synthetic" * Char(0x80), "synthetic" * repeat("\\", 20))
        mktempdir() do root
            terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), [key])
            redact = text -> JuliaForever.redact(terminal, text)
            missing = joinpath(root, "missing-" * key * "a.sqlite")
            request = Catalog.Target(missing)
            result = Catalog.choose(request, root, root, IOBuffer(), IOBuffer(), redact)
            @test result isa Catalog.Invalid
            @test occursin("missing-[redacted]a.sqlite", result.message)
            @test !occursin(chop(repr(key * "a"); head=1, tail=1), result.message)
            raw = Catalog.choose(request, root, root, IOBuffer(), IOBuffer())
            @test occursin(repr(missing), raw.message)

            if !Sys.iswindows() || !occursin('\\', key)
                path = joinpath(root, "exists-" * key * "a.sqlite")
                close(open(H.SQLite, path))
                selected = Catalog.choose(Catalog.Target(path), root, root, IOBuffer(), IOBuffer(), redact)
                @test selected isa H.SQLite
                close(selected)
            end
        end
    end
end
