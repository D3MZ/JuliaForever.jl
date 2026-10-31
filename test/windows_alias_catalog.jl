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

end
