using Test, JSON3, JuliaForever

import JuliaForever.Durable as D

reason(x) = x isa D.Rejected ? x.reason : nothing
ids(rows) = [row.id for row in rows]

if Sys.isunix()
@testset "durable transcript forks" begin
    mktempdir() do dir
        path = joinpath(dir, "forks.jsonl")
        store = open(D.Store, path)
        root, first, cutoff, excluded = D.commit!(store) do tx
            root = D.mint!(tx)
            D.put!(tx, D.Conversation(root, Dict("name" => "root")))
            first = D.mint!(tx)
            D.put!(tx, D.Entry(first, root, "note", Dict("text" => "first")))
            cutoff = D.mint!(tx)
            D.put!(tx, D.Entry(cutoff, root, "note", "cutoff"))
            excluded = D.mint!(tx)
            D.put!(tx, D.Entry(excluded, root, "note", "same batch, after cutoff"))
            (root, first, cutoff, excluded)
        end
        child = D.commit!(store) do tx
            D.fork!(tx, Int32(root), Int32(cutoff); value=Dict("name" => "child"))
        end
        @test child isa Int
        @test get(store, D.Conversation, child).parent == (root, cutoff)
        @test ids(D.entries(store, child)) == [first, cutoff]
        rows = D.entries(store, child)
        rows[1].value["text"] = "changed"
        @test D.entries(store, child)[1].value["text"] == "first"

        childfirst, childhidden = D.commit!(store) do tx
            childfirst = D.mint!(tx)
            D.put!(tx, D.Entry(childfirst, child, "note", "child"))
            childhidden = D.mint!(tx)
            D.put!(tx, D.Entry(childhidden, child, "note", "later child"))
            @test ids(D.entries(tx, child)) == [first, cutoff, childfirst, childhidden]
            (childfirst, childhidden)
        end
        later = D.commit!(store) do tx
            id = D.mint!(tx)
            D.put!(tx, D.Entry(id, root, "note", "later root"))
            id
        end
        grandchild = D.commit!(store) do tx
            D.fork!(tx, child, childfirst)
        end
        inherited = D.commit!(store) do tx
            D.fork!(tx, child, first)
        end
        grandtail = D.commit!(store) do tx
            id = D.mint!(tx)
            D.put!(tx, D.Entry(id, grandchild, "note", "grandchild"))
            id
        end
        @test ids(D.entries(store, root)) == [first, cutoff, excluded, later]
        @test ids(D.entries(store, child)) == [first, cutoff, childfirst, childhidden]
        @test ids(D.entries(store, grandchild)) == [first, cutoff, childfirst, grandtail]
        @test ids(D.entries(store, inherited)) == [first]
        @test ids(D.scan(store, D.Entry; conversation=grandchild)) == [grandtail]
        @test reason(D.entries(store, 999_999)) == :conversation_missing

        before = D.revision(store)
        rejected = D.commit!(store) do tx
            D.put!(tx, D.Entry(D.mint!(tx), grandchild, "note", "rolled back"))
            D.fork!(tx, child, excluded)
            :ignored
        end
        @test reason(rejected) == :fork_point_missing
        @test D.revision(store) == before
        @test ids(D.entries(store, grandchild)) == [first, cutoff, childfirst, grandtail]
        @test reason(D.commit!(tx -> D.fork!(tx, 999_999, first), store)) == :conversation_missing
        @test reason(D.commit!(tx -> D.fork!(tx, root, grandtail), store)) == :fork_point_missing
        @test reason(D.commit!(tx -> D.fork!(tx, child, later), store)) == :fork_point_missing
        @test reason(D.commit!(store) do tx
            new = D.mint!(tx)
            D.put!(tx, D.Entry(new, root, "note", "uncommitted"))
            D.fork!(tx, root, new)
        end) == :fork_point_missing
        @test D.revision(store) == before
        held = Ref{Any}()
        D.commit!(store) do tx
            held[] = tx
            @test reason(fetch(@async D.entries(tx, root))) == :foreign_task
        end
        @test reason(D.entries(held[], root)) == :expired_transaction
        @test reason(D.fork!(held[], root, first)) == :expired_transaction
        @test reason(D.commit!(tx -> D.put!(tx, D.Conversation(root, nothing, (root, excluded))), store)) == :immutable

        close(store)
        @test reason(D.entries(store, child)) == :closed
        store = open(D.Store, path)
        @test get(store, D.Conversation, child).parent == (root, cutoff)
        @test ids(D.entries(store, grandchild)) == [first, cutoff, childfirst, grandtail]
        @test ids(D.entries(store, inherited)) == [first]
        close(store)
    end
end

@testset "fork document boundary" begin
    mktempdir() do dir
        store = open(D.Store, joinpath(dir, "forks.jsonl"))
        root, first, other = D.commit!(store) do tx
            root, other = D.mint!(tx), D.mint!(tx)
            D.put!(tx, D.Conversation(root, nothing))
            D.put!(tx, D.Conversation(other, nothing))
            first = D.mint!(tx)
            D.put!(tx, D.Entry(first, root, "note", "a"))
            D.put!(tx, D.Task(D.mint!(tx), root, "root task"))
            D.submit!(tx, root; request="request", value="root submission")
            D.put!(tx, D.Document(D.mint!(tx), other, "unrelated"))
            (root, first, other)
        end
        child = D.commit!(tx -> D.fork!(tx, root, first), store)
        @test child isa Int
        @test isempty(D.scan(store, D.Task; conversation=child))
        @test isempty(D.scan(store, D.Submission; conversation=child))
        before = D.revision(store)
        result = D.commit!(store) do tx
            fork = D.fork!(tx, child, first)
            D.put!(tx, D.Document(D.mint!(tx), root, "late staged document"))
            fork
        end
        @test reason(result) == :fork_documents_unsupported
        @test D.revision(store) == before
        @test isempty(D.scan(store, D.Document; conversation=root))
        D.commit!(store) do tx
            D.put!(tx, D.Document(D.mint!(tx), root, "now present"))
        end
        before = D.revision(store)
        @test reason(D.commit!(tx -> D.fork!(tx, root, first), store)) == :fork_documents_unsupported
        @test reason(D.commit!(tx -> D.fork!(tx, child, first), store)) == :fork_documents_unsupported
        @test reason(D.commit!(store) do tx
            D.put!(tx, D.Conversation(D.mint!(tx), nothing, (root, first)))
        end) == :fork_documents_unsupported
        @test D.revision(store) == before
        close(store)
        store = open(D.Store, joinpath(dir, "forks.jsonl"))
        @test ids(D.entries(store, child)) == [first]
        @test reason(D.commit!(tx -> D.fork!(tx, child, first), store)) == :fork_documents_unsupported
        close(store)
    end
end

@testset "fork log validation" begin
    mktempdir() do dir
        path = joinpath(dir, "legacy.jsonl")
        legacy = JSON3.write((; seq=1, nextid=2, writes=[(; type="conversation", id=1, value=nothing), (; type="entry", id=2, conversation=1, kind="note", value="legacy")])) * "\n"
        write(path, legacy)
        store = open(D.Store, path)
        @test get(store, D.Conversation, 1).parent === nothing
        fork = D.commit!(tx -> D.fork!(tx, 1, 2), store)
        @test ids(D.entries(store, fork)) == [2]
        close(store)
        store = open(D.Store, path)
        @test ids(D.entries(store, fork)) == [2]
        close(store)

        invalids = [
            [(; type="conversation", id=3, value=nothing, parent=(; conversation=1, at=999))],
            [(; type="conversation", id=3, value=nothing, parent=(; conversation=999, at=2))],
            [(; type="conversation", id=3, value=nothing, parent=(; conversation=1, at=true))],
            [(; type="conversation", id=3, value=nothing, parent=[1, 2])],
            [(; type="entry", id=3, conversation=1, kind="note", value="staged"), (; type="conversation", id=4, value=nothing, parent=(; conversation=1, at=3))],
            [(; type="conversation", id=3, value=nothing, parent=(; conversation=1, at=2)), (; type="document", id=4, conversation=1, value="staged")],
            [(; type="entry", id=2, conversation=1, kind="note", value="duplicate")],
        ]
        for (i, writes) in enumerate(invalids)
            file = joinpath(dir, "invalid-$i.jsonl")
            bytes = legacy * JSON3.write((; seq=2, nextid=4, writes)) * "\n"
            write(file, bytes)
            @test reason(open(D.Store, file)) == :corrupt_log
            @test read(file, String) == bytes
        end

        file = joinpath(dir, "retroactive.jsonl")
        batches = [
            (; seq=1, nextid=4, writes=[(; type="conversation", id=1, value=nothing), (; type="entry", id=4, conversation=1, kind="note", value="cutoff")]),
            (; seq=2, nextid=5, writes=[(; type="conversation", id=5, value=nothing, parent=(; conversation=1, at=4))]),
            (; seq=3, nextid=5, writes=[(; type="entry", id=3, conversation=1, kind="note", value="retroactive")]),
        ]
        bytes = join(JSON3.write(batch) * "\n" for batch in batches)
        write(file, bytes)
        @test reason(open(D.Store, file)) == :corrupt_log
        @test read(file, String) == bytes
    end
end

@testset "fork survives abrupt process exit" begin
    mktempdir() do dir
        path = joinpath(dir, "crash.jsonl")
        project = dirname(@__DIR__)
        script = """
            using JuliaForever
            import JuliaForever.Durable as D
            store = open(D.Store, ARGS[1])
            root, first = D.commit!(store) do tx
                root = D.mint!(tx)
                D.put!(tx, D.Conversation(root, nothing))
                first = D.mint!(tx)
                D.put!(tx, D.Entry(first, root, "note", "before"))
                (root, first)
            end
            child = D.commit!(tx -> D.fork!(tx, root, first), store)
            tail = D.commit!(store) do tx
                id = D.mint!(tx)
                D.put!(tx, D.Entry(id, child, "note", "after"))
                id
            end
            println(join((root, first, child, tail), ","))
            flush(stdout)
            ccall(:_exit, Cvoid, (Cint,), 0)
        """
        root, first, child, tail = parse.(Int, split(strip(read(`$(Base.julia_cmd()) --project=$project -e $script $path`, String)), ','))
        store = open(D.Store, path)
        @test get(store, D.Conversation, child).parent == (root, first)
        @test ids(D.entries(store, child)) == [first, tail]
        close(store)
        good = read(path)
        open(path, "a") do io
            write(io, "{\"seq\":4,\"writes\":[")
        end
        store = open(D.Store, path)
        @test ids(D.entries(store, child)) == [first, tail]
        @test read(path) == good
        close(store)
    end
end
end
