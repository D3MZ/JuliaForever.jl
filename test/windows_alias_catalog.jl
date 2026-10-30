module WindowsAliasCatalogTests

using Test, JuliaForever, SHA, SQLite
import JuliaForever.History as H
import JuliaForever.SessionCatalog as Catalog
import JuliaForever.Conversation as C

struct FixtureProject <: AbstractString
    aliases::Vector{String}
end
Catalog.spellings(project::FixtureProject) = project.aliases

function createsession(dir, cwd, id, title)
    file = joinpath(dir, Catalog.filename(cwd, id))
    tree = H.Tree(Catalog.Deferred(file))
    try
        initial = C.State("fixture"; automatic=false)
        @test H.append!(tree, 0, Any[H.encode_initial(initial)]) == 1
        @test H.append!(tree, 1, Any[H.encode(C.Input(0, title))]) == 2
    finally
        close(tree)
    end
    file
end

@testset "Windows alias catalogs preserve sessions and reject duplicate IDs" begin
    mktempdir() do root
        long = joinpath(root, "Project Long")
        short = joinpath(root, "PROJEC~1")
        other = joinpath(root, "Other")
        firstid, secondid, duplicate = repeat("1", 32), repeat("2", 32), repeat("a", 32)
        first = createsession(root, long, firstid, "long session")
        second = createsession(root, short, secondid, "short session")
        duplicate1 = createsession(root, long, duplicate, "long duplicate")
        duplicate2 = createsession(root, short, duplicate, "short duplicate")
        unrelated = createsession(root, other, repeat("3", 32), "other session")
        originals = Dict(path => bytes2hex(sha256(read(path))) for path in (first, second, duplicate1, duplicate2, unrelated))
        project = FixtureProject([long, short])
        choices = Catalog.list(root, project)
        @test Set(item.path for item in choices) == Set((first, second, duplicate1, duplicate2))
        @test Set(item.title for item in choices) == Set(("long session", "short session", "long duplicate", "short duplicate"))
        for request in (Catalog.Target(duplicate), Catalog.Fork(duplicate))
            result = Catalog.choose(request, root, project, IOBuffer(), IOBuffer())
            @test result isa Catalog.Invalid
            @test occursin("No unique session", result.message)
        end
        selected = Catalog.choose(Catalog.Target(firstid), root, project, IOBuffer(), IOBuffer())
        @test selected isa H.Tree && Catalog.path(selected) == first
        close(selected)
        active = open(H.SQLite, first; create=false)
        try
            SQLite.execute(active.db, "BEGIN IMMEDIATE")
            @test Set(item.path for item in Catalog.list(root, project)) == Set((first, second, duplicate1, duplicate2))
            SQLite.execute(active.db, "ROLLBACK")
        finally
            close(active)
        end
        recent = Catalog.choose(Catalog.Recent(), root, project, IOBuffer(), IOBuffer())
        @test recent isa H.Tree && Catalog.path(recent) == duplicate2
        close(recent)
        @test Dict(path => bytes2hex(sha256(read(path))) for path in keys(originals)) == originals
        stale = only(filter(item -> item.path == second, choices))
        rm(second)
        @test Catalog.openinfo(stale) == H.Rejected(:history_missing)
        @test !isfile(second)
        @test Set(item.path for item in Catalog.list(root, project)) == Set((first, duplicate1, duplicate2))
    end
end

@testset "Windows path conversion handles UTF-16 and buffer boundaries" begin
    mktempdir() do dir
        original = joinpath(dir, "Mixed 長い 😀")
        expected = joinpath(dir, "LONG~1 😀")
        function success(input, output)
            @test transcode(String, input[1:end-1]) == abspath(original)
            units = transcode(UInt16, expected)
            output[1:length(units)] = units
            UInt32(length(units))
        end
        @test Catalog.winpath(original, success) == expected
        @test Catalog.winpath(original, (input, output) -> UInt32(0)) == abspath(original)
        @test Catalog.winpath(original, (input, output) -> UInt32(length(output))) == abspath(original)
        @test Catalog.winpath(original, (input, output) -> UInt32(length(output) + 1)) == abspath(original)
    end
end

end
