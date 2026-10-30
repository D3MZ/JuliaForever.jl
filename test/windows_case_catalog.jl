module WindowsCaseCatalogTests

using Test, JuliaForever, SHA, SQLite
import JuliaForever.History as H
import JuliaForever.SessionCatalog as Catalog
import JuliaForever.Conversation as C

struct FixtureCaseProject <: AbstractString
    path::String
end
Catalog.spellings(project::FixtureCaseProject) = (project.path,)
Catalog.projectlist(dir, project::FixtureCaseProject, paths) = Catalog.listcase(dir, paths)
struct CaseProvider end
JuliaForever.complete(::CaseProvider, messages, tools) = Dict("role" => "assistant", "content" => "reply")

function session(dir, cwd, id, title; recorded=cwd)
    file = joinpath(dir, Catalog.filename(cwd, id))
    prompt = JuliaForever.context(recorded, JuliaForever.Tool[], [])
    state = C.State("fixture"; automatic=false, messages=C.Message[C.RawMessage(Dict("role" => "system", "content" => prompt))])
    tree = H.Tree(Catalog.Deferred(file))
    try
        @test H.append!(tree, 0, Any[H.encode_initial(state)]) == 1
        @test H.append!(tree, 1, Any[H.encode(C.Input(0, title))]) == 2
    finally
        close(tree)
    end
    file
end

@testset "Case aliases recover existing sessions without rewriting catalogs" begin
    mktempdir() do root
        original = joinpath(root, "Case Variant Project Ω")
        altered = joinpath(root, "cASE vARIANT pROJECT Ω")
        other = joinpath(root, "Other Project")
        mkpath(original); mkpath(other)
        isdir(altered) || symlink(original, altered; dir_target=true)
        @test samefile(original, altered)
        id1, id2, duplicate = repeat("1", 32), repeat("2", 32), repeat("a", 32)
        first = session(root, original, id1, "original")
        second = session(root, altered, id2, "alternate case")
        duplicate1 = session(root, original, duplicate, "original duplicate")
        duplicate2 = session(root, altered, duplicate, "alternate duplicate")
        unrelated = session(root, other, repeat("3", 32), "unrelated")
        forged = session(root, other, repeat("4", 32), "forged"; recorded=altered)
        corrupt = joinpath(root, Catalog.filename(other, repeat("5", 32)))
        write(corrupt, "not a SQLite history")
        malformed = joinpath(root, Catalog.filename(other, repeat("6", 32)))
        broken = SQLite.DB(malformed)
        try
            SQLite.execute(broken, "CREATE TABLE jf_meta (format TEXT)")
            SQLite.execute(broken, "INSERT INTO jf_meta VALUES ('JuliaForever.History.SQLite/1')")
            SQLite.execute(broken, "CREATE TABLE jf_history (revision INTEGER, data TEXT)")
            SQLite.execute(broken, "INSERT INTO jf_history VALUES (1, '{synthetic-secret')")
        finally
            SQLite.close(broken)
        end
        paths = (first, second, duplicate1, duplicate2, unrelated, forged, corrupt, malformed)
        before = Dict(path => bytes2hex(sha256(read(path))) for path in paths)
        for cwd in (original, altered)
            choices = Catalog.listcase(root, (cwd,))
            @test Set(item.path for item in choices) == Set((first, second, duplicate1, duplicate2))
            @test Set(item.title for item in choices) == Set(("original", "alternate case", "original duplicate", "alternate duplicate"))
            for request in (Catalog.Target(duplicate), Catalog.Fork(duplicate))
                result = Catalog.choose(request, root, FixtureCaseProject(cwd), IOBuffer(), IOBuffer())
                @test result isa Catalog.Invalid
                @test occursin("No unique session", result.message)
            end
        end
        @test Dict(path => bytes2hex(sha256(read(path))) for path in paths) == before
        @test Catalog.casecandidate(second, id2, Catalog.project(altered), (other,), [abspath(altered)]) === nothing
        blob = joinpath(root, Catalog.filename(altered, repeat("7", 32)))
        cp(second, blob)
        blobdb = SQLite.DB(blob)
        try
            SQLite.execute(blobdb, "UPDATE jf_history SET data=CAST(data AS BLOB) WHERE revision=1")
        finally
            SQLite.close(blobdb)
        end
        @test Catalog.casecandidate(blob, repeat("7", 32), Catalog.project(altered), (original,), [original]) === nothing
        rm(blob)
        extra = joinpath(root, Catalog.filename(altered, repeat("8", 32)))
        cp(second, extra)
        extrad = SQLite.DB(extra)
        try
            SQLite.execute(extrad, "CREATE TABLE unrelated (value TEXT)")
        finally
            SQLite.close(extrad)
        end
        @test Catalog.casecandidate(extra, repeat("8", 32), Catalog.project(altered), (original,), [original]) === nothing
        rm(extra)
        forkdir = joinpath(root, "forks")
        source = Catalog.new(forkdir, original)
        messages = Dict{String, Any}[Dict("role" => "system", "content" => JuliaForever.context(original, JuliaForever.Tool[], []))]
        @test JuliaForever.respond!(JuliaForever.Agent(CaseProvider(), [], messages; history=source), "fork source") == "reply"
        sourcefile = Catalog.path(source)
        close(source)
        function forkto(destination)
            source = Catalog.wrap(open(H.SQLite, sourcefile; create=false))
            copied = Catalog.fork(source, forkdir, destination)
            file = Catalog.path(copied)
            close(copied)
            file
        end
        casefork = forkto(altered)
        crossfork = forkto(other)
        source = Catalog.wrap(open(H.SQLite, sourcefile; create=false))
        branchfork = Catalog.duplicate(Catalog.new(forkdir, altered), Catalog.branchpath(source, source.leaf), Catalog.Path())
        branchfile = Catalog.path(branchfork)
        close(branchfork)
        close(source)
        forkbytes = Dict(file => read(file) for file in (sourcefile, casefork, crossfork, branchfile))
        @test casefork in Set(item.path for item in Catalog.listcase(forkdir, (altered,)))
        @test casefork in Set(item.path for item in Catalog.listcase(forkdir, (original,)))
        @test branchfile in Set(item.path for item in Catalog.listcase(forkdir, (original,)))
        @test crossfork ∉ Set(item.path for item in Catalog.listcase(forkdir, (original,)))
        @test Dict(file => read(file) for file in keys(forkbytes)) == forkbytes
        forkactive = open(H.SQLite, casefork; create=false)
        try
            SQLite.execute(forkactive.db, "PRAGMA journal_mode=WAL")
            SQLite.execute(forkactive.db, "UPDATE jf_meta SET cwd=cwd")
            wal = casefork * "-wal"
            @test isfile(wal)
            beforefork = (read(casefork), read(wal))
            @test casefork in Set(item.path for item in Catalog.listcase(forkdir, (original,)))
            @test (read(casefork), read(wal)) == beforefork
        finally
            close(forkactive)
        end
        active = open(H.SQLite, second; create=false)
        try
            SQLite.execute(active.db, "PRAGMA journal_mode=WAL")
            SQLite.execute(active.db, "UPDATE jf_meta SET format=format")
            wal = second * "-wal"
            @test isfile(wal)
            dbhash, walhash = bytes2hex(sha256(read(second))), bytes2hex(sha256(read(wal)))
            @test second in Set(item.path for item in Catalog.listcase(root, (original,)))
            @test bytes2hex(sha256(read(second))) == dbhash
            @test bytes2hex(sha256(read(wal))) == walhash
            Catalog.readonly(second) do reader
                @test Catalog.historyrows(reader, Catalog.historyquery * " LIMIT 1").revision == 1
                @test H.append!(active, 2, Any[H.encode(C.Input(1, "concurrent update"))]) == 3
                @test Catalog.historyrows(reader, Catalog.historyquery).revision == 2
            end
            @test H.snapshot(active).revision == 3
        finally
            close(active)
        end
        rm(second)
        @test Set(item.path for item in Catalog.listcase(root, (original,))) == Set((first, duplicate1, duplicate2))
        @test !isfile(second)
    end
end

@testset "Stale and inaccessible case candidates do not interrupt discovery" begin
    mktempdir() do root
        workspace = joinpath(root, "Project")
        missing = joinpath(root, "Missing Project")
        malformed = joinpath(root, "Invalid\0Path")
        mkpath(workspace)
        current = session(root, workspace, repeat("1", 32), "current")
        stale = session(root, missing, repeat("2", 32), "stale")
        invalid = session(root, malformed, repeat("3", 32), "malformed")
        paths = (workspace, uppercase(missing))
        files = [current, stale, invalid]
        if !Sys.iswindows()
            loop = joinpath(root, "Loop Project")
            symlink("Loop Project", loop)
            inaccessible = session(root, loop, repeat("4", 32), "inaccessible")
            push!(files, inaccessible)
            paths = (paths..., uppercase(loop))
        end
        before = Dict(file => bytes2hex(sha256(read(file))) for file in files)
        @test Set(item.path for item in Catalog.listcase(root, paths)) == Set((current,))
        @test Dict(file => bytes2hex(sha256(read(file))) for file in files) == before
    end
end

@testset "Windows case-sensitive projects remain separate" begin
    if Sys.iswindows() && haskey(ENV, "JF_CASE_SENSITIVE_TEST_ROOT")
        mktempdir(ENV["JF_CASE_SENSITIVE_TEST_ROOT"]) do root
            workspace = joinpath(root, "Case Project")
            alternate = joinpath(root, "cASE pROJECT")
            mkpath(workspace)
            @test !ispath(alternate)
            current = session(root, workspace, repeat("1", 32), "current")
            stale = session(root, alternate, repeat("2", 32), "other case")
            files = (current, stale)
            before = Dict(file => bytes2hex(sha256(read(file))) for file in files)
            @test Set(item.path for item in Catalog.list(root, workspace)) == Set((current,))
            mkpath(alternate)
            @test !samefile(workspace, alternate)
            @test Set(item.path for item in Catalog.list(root, workspace)) == Set((current,))
            @test Dict(file => bytes2hex(sha256(read(file))) for file in files) == before
            source = Catalog.new(root, workspace)
            messages = Dict{String, Any}[Dict("role" => "system", "content" => JuliaForever.context(workspace, JuliaForever.Tool[], []))]
            @test JuliaForever.respond!(JuliaForever.Agent(CaseProvider(), [], messages; history=source), "source") == "reply"
            copied = Catalog.fork(source, root, alternate)
            forkfile = Catalog.path(copied)
            close(copied)
            @test forkfile in Set(item.path for item in Catalog.list(root, alternate))
            @test forkfile ∉ Set(item.path for item in Catalog.list(root, workspace))
        end
    end
end


@testset "Locked unrelated catalogs are skipped promptly" begin
    mktempdir() do root
        original = joinpath(root, "Case Project")
        alternate = joinpath(root, "cASE pROJECT")
        other = joinpath(root, "Other Project")
        mkpath.((original, other))
        isdir(alternate) || symlink(original, alternate; dir_target=true)
        id = repeat("a", 32)
        direct = session(root, original, id, "direct")
        alias = session(root, alternate, id, "alias")
        locked = [session(root, other, repeat(string(i), 32), "unrelated") for i in 1:3]
        databases = SQLite.DB[]
        try
            for path in locked
                db = SQLite.DB(path)
                push!(databases, db)
                SQLite.execute(db, "BEGIN EXCLUSIVE")
            end
            files = [direct, alias, locked...]
            before = Dict(path => read(path) for path in files)
            elapsed = @elapsed choices = Catalog.listcase(root, (original,))
            @info "locked catalog scan" elapsed
            @test elapsed < 3
            @test Set(item.path for item in choices) == Set((direct, alias))
            result = Catalog.choose(Catalog.Target(id), root, FixtureCaseProject(original), IOBuffer(), IOBuffer())
            @test result isa Catalog.Invalid
            @test Dict(path => read(path) for path in files) == before
        finally
            for db in databases
                SQLite.execute(db, "ROLLBACK")
                SQLite.close(db)
            end
        end
    end
end

end
