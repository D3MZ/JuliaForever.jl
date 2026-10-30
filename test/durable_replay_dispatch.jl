using Test, JSON3, JuliaForever

@testset "durable replay outcomes" begin
    if Sys.isunix()
        durable = JuliaForever.Durable
        conversation = Dict("type" => "conversation", "id" => 1, "value" => "ok", "parent" => nothing)
        valid = Dict{String, Any}("seq" => 1, "nextid" => 1, "writes" => Any[conversation])
        entry = Dict("type" => "entry", "id" => 1, "conversation" => 999, "kind" => "input", "value" => "bad")
        bad = Any[
            merge(valid, Dict("seq" => true)),
            merge(valid, Dict("seq" => 2)),
            merge(valid, Dict("nextid" => "1")),
            merge(valid, Dict("nextid" => 0)),
            merge(valid, Dict("writes" => "not an array")),
            merge(valid, Dict("writes" => Any[])),
            merge(valid, Dict("writes" => Any[Dict("type" => "unknown", "id" => 1)])),
            merge(valid, Dict("writes" => Any[entry])),
            Dict("seq" => 1),
        ]
        mktempdir() do dir
            created = open(durable.Store, joinpath(dir, "created.jsonl"))
            durable.commit!(created) do tx
                id = durable.mint!(tx)
                durable.put!(tx, durable.Conversation(id, "created"))
                durable.put!(tx, durable.Entry(durable.mint!(tx), id, "input", "saved"))
            end
            close(created)
            created = open(durable.Store, joinpath(dir, "created.jsonl"))
            @test get(created, durable.Conversation, 1).value == "created"
            @test get(created, durable.Entry, 2).value == "saved"
            close(created)
            path = joinpath(dir, "history.jsonl")
            good = JSON3.write(valid) * "\n"
            write(path, good)
            store = open(durable.Store, path)
            @test durable.revision(store) == 1
            @test get(store, durable.Conversation, 1).value == "ok"
            close(store)
            for batch in bad
                bytes = JSON3.write(batch) * "\n"
                write(path, bytes)
                @test open(durable.Store, path) == durable.Rejected(:corrupt_log)
                @test read(path, String) == bytes
            end
            bytes = good * JSON3.write(merge(valid, Dict("seq" => 2))) * "\n"
            write(path, bytes)
            @test open(durable.Store, path) == durable.Rejected(:corrupt_log)
            @test read(path, String) == bytes
        end
    end
end
