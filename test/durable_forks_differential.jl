using Test, JSON3, JuliaForever

import JuliaForever.Durable as D

@testset "durable transcript forks: Pi B1 oracle" begin
    @test readchomp(`git -C $(ENV["PI_SOURCE"]) rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    script = joinpath(@__DIR__, "durable_forks_reference.mjs")
    reference = JSON3.read(read(`node --conditions=source --experimental-strip-types $script $(ENV["PI_SOURCE"])`, String), Dict{String, Any})
    mktempdir() do dir
        store = open(D.Store, joinpath(dir, "forks.jsonl"))
        root, first, cutoff, excluded = D.commit!(store) do tx
            root = D.mint!(tx)
            D.put!(tx, D.Conversation(root, nothing))
            first = D.mint!(tx)
            D.put!(tx, D.Entry(first, root, "note", "first"))
            cutoff = D.mint!(tx)
            D.put!(tx, D.Entry(cutoff, root, "note", "cutoff"))
            excluded = D.mint!(tx)
            D.put!(tx, D.Entry(excluded, root, "note", "same-batch-excluded"))
            (root, first, cutoff, excluded)
        end
        child = D.commit!(tx -> D.fork!(tx, root, cutoff), store)
        childfirst = D.commit!(store) do tx
            childfirst = D.mint!(tx)
            D.put!(tx, D.Entry(childfirst, child, "note", "child"))
            D.put!(tx, D.Entry(D.mint!(tx), child, "note", "later-child"))
            childfirst
        end
        D.commit!(store) do tx
            D.put!(tx, D.Entry(D.mint!(tx), root, "note", "later-root"))
        end
        grandchild = D.commit!(tx -> D.fork!(tx, child, childfirst), store)
        inherited = D.commit!(tx -> D.fork!(tx, child, first), store)
        D.commit!(store) do tx
            D.put!(tx, D.Entry(D.mint!(tx), grandchild, "note", "grandchild"))
        end
        view(id) = [entry.value for entry in D.entries(store, id)]
        hidden = D.commit!(tx -> D.fork!(tx, child, excluded), store)
        staged = D.commit!(store) do tx
            id = D.mint!(tx)
            D.put!(tx, D.Entry(id, root, "note", "uncommitted"))
            D.fork!(tx, root, id)
        end
        result = Dict("root" => view(root), "child" => view(child), "grandchild" => view(grandchild), "inherited" => view(inherited), "hiddenRejected" => hidden isa D.Rejected, "stagedRejected" => staged isa D.Rejected)
        @test result == reference
        close(store)
    end
end
