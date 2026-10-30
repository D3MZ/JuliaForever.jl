module DurableDocumentTests

using Test, JuliaForever
import JuliaForever.Durable as D

if Sys.isunix()
@testset "durable document snapshots" begin
    mktempdir() do dir
        path = joinpath(dir, "history.jsonl")
        store = open(D.Store, path)
        chat, other = D.commit!(store) do tx
            chat, other = D.mint!(tx), D.mint!(tx)
            D.put!(tx, D.Conversation(chat, nothing))
            D.put!(tx, D.Conversation(other, nothing))
            chat, other
        end
        before = D.commit!(store) do tx
            D.put!(tx, D.Entry(D.mint!(tx), chat, "before", nothing))
        end
        first, same, document, foreign = D.commit!(store) do tx
            first = D.put!(tx, D.Entry(D.mint!(tx), chat, "first", nothing))
            document = D.mint!(tx)
            D.put!(tx, D.Document(document, chat, Dict("items" => ["intermediate"])))
            same = D.put!(tx, D.Entry(D.mint!(tx), chat, "same batch", nothing))
            D.put!(tx, D.Document(document, chat, Dict("items" => ["first"])))
            foreign = D.put!(tx, D.Entry(D.mint!(tx), other, "foreign", nothing))
            first, same, document, foreign
        end
        @test D.snapshot(store, chat, document, before) === nothing
        @test D.snapshot(store, chat, document, first).value == Dict("items" => ["first"])
        @test D.snapshot(store, chat, document, same).value == Dict("items" => ["first"])
        @test D.snapshot(store, chat, 999, first) === nothing
        @test D.snapshot(store, other, document, foreign) === nothing
        @test D.snapshot(store, chat, document, foreign) == D.Rejected(:entry_not_visible)
        @test D.snapshot(store, chat, document, 999) == D.Rejected(:entry_not_visible)
        @test D.snapshot(store, chat, document, chat) == D.Rejected(:entry_not_visible)

        snapshot = D.snapshot(store, chat, document, first)
        push!(snapshot.value["items"], "changed")
        @test D.snapshot(store, chat, document, first).value == Dict("items" => ["first"])

        rejected = D.commit!(store) do tx
            D.put!(tx, D.Document(document, chat, Dict("items" => ["rolled back"])))
            D.put!(tx, D.Document(D.mint!(tx), 999, nothing))
        end
        @test rejected == D.Rejected(:conversation_missing)
        @test D.revision(store) == 3

        second, null = D.commit!(store) do tx
            D.put!(tx, D.Document(document, chat, Dict("items" => ["second"])))
            null = D.mint!(tx)
            D.put!(tx, D.Document(null, chat, nothing))
            D.put!(tx, D.Entry(D.mint!(tx), chat, "second", nothing)), null
        end
        @test D.snapshot(store, chat, document, first).value == Dict("items" => ["first"])
        @test D.snapshot(store, chat, document, second).value == Dict("items" => ["second"])
        @test D.snapshot(store, chat, null, first) === nothing
        @test D.snapshot(store, chat, null, second).value === nothing
        close(store)
        @test D.snapshot(store, chat, document, first) == D.Rejected(:closed)

        store = open(D.Store, path)
        @test D.snapshot(store, chat, document, before) === nothing
        @test D.snapshot(store, chat, document, first).value == Dict("items" => ["first"])
        @test D.snapshot(store, chat, document, same).value == Dict("items" => ["first"])
        @test D.snapshot(store, chat, document, second).value == Dict("items" => ["second"])
        @test D.snapshot(store, chat, null, second).value === nothing
        third = D.commit!(store) do tx
            entry = D.put!(tx, D.Entry(D.mint!(tx), chat, "third", nothing))
            D.put!(tx, D.Document(document, chat, Dict("items" => ["third"])))
            entry
        end
        @test D.snapshot(store, chat, document, second).value == Dict("items" => ["second"])
        @test D.snapshot(store, chat, document, third).value == Dict("items" => ["third"])
        close(store)
    end
end
end

end
