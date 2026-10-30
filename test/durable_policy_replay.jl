module DurablePolicyReplayTests

using Test, JSON3, JuliaForever
import JuliaForever.Durable as D

if Sys.isunix()
@testset "document fork replay validates copies and source writes" begin
    mktempdir() do dir
        path = joinpath(dir, "valid.jsonl")
        store = open(D.Store, path)
        root, point, first, second = D.commit!(store) do tx
            root = D.mint!(tx)
            D.put!(tx, D.Conversation(root, nothing))
            point = D.put!(tx, D.Entry(D.mint!(tx), root, "point", "point"))
            first, second = D.mint!(tx), D.mint!(tx)
            D.put!(tx, D.PolicyDocument(first, root, "notes", nothing, D.AsOf(), Dict("value" => "one")))
            D.put!(tx, D.PolicyDocument(second, root, "notes", "key", D.Current(), Dict("value" => "two")))
            root, point, first, second
        end
        child = D.commit!(tx -> D.fork!(tx, root, point), store)
        @test child isa Int
        close(store)
        store = open(D.Store, path)
        @test length(D.scan(store, D.PolicyDocument; conversation=child)) == 2
        close(store)
        batches = [JSON3.read(line, Dict{String, Any}) for line in readlines(path)]
        variants = Dict{String, Function}(
            "missing copy" => fork -> empty!(fork["copies"]),
            "wrong source" => fork -> fork["copies"][1]["source"] = 999999,
            "duplicate target" => fork -> fork["copies"][2]["id"] = fork["copies"][1]["id"],
            "conversation target" => fork -> fork["copies"][1]["id"] = fork["id"],
            "old target" => fork -> fork["copies"][1]["id"] = first,
            "future target" => fork -> fork["copies"][1]["id"] = 999999,
            "invalid point" => fork -> fork["parent"]["at"] = 999999,
        )
        for (name, mutate!) in variants
            forged = deepcopy(batches)
            fork = only(forged[2]["writes"])
            mutate!(fork)
            bytes = join(JSON3.write(batch) * "\n" for batch in forged)
            file = joinpath(dir, replace(name, ' ' => '-') * ".jsonl")
            write(file, bytes)
            @test open(D.Store, file) == D.Rejected(:corrupt_log)
            @test read(file, String) == bytes
        end
        for position in (:before, :after)
            forged = deepcopy(batches)
            source = deepcopy(only(filter(record -> record["id"] == first, forged[1]["writes"])))
            source["value"] = Dict("value" => "staged")
            position == :before ? pushfirst!(forged[2]["writes"], source) : push!(forged[2]["writes"], source)
            file = joinpath(dir, "source-$position.jsonl")
            write(file, join(JSON3.write(batch) * "\n" for batch in forged))
            @test open(D.Store, file) == D.Rejected(:corrupt_log)
        end
        forged = deepcopy(batches)
        fork = only(forged[2]["writes"])
        forged[2]["writes"] = [Dict("type" => "conversation", "id" => fork["id"], "value" => fork["value"], "parent" => fork["parent"])]
        file = joinpath(dir, "raw-conversation.jsonl")
        write(file, join(JSON3.write(batch) * "\n" for batch in forged))
        @test open(D.Store, file) == D.Rejected(:corrupt_log)

        forged = deepcopy(batches)
        documents = filter(record -> record["type"] == "policy_document", forged[1]["writes"])
        documents[2]["key"] = documents[1]["key"]
        file = joinpath(dir, "duplicate-address.jsonl")
        write(file, join(JSON3.write(batch) * "\n" for batch in forged))
        @test open(D.Store, file) == D.Rejected(:corrupt_log)
    end
end
end

end
