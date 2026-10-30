module DurableDocumentDifferential

using Test, JSON3, JuliaForever
import JuliaForever.Durable as D

value(::Nothing) = nothing
value(document::D.Document) = document.value

if Sys.isunix()
@testset "durable document history versus Pi" begin
    @test readchomp(`git -C $(ENV["PI_SOURCE"]) rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    loader = joinpath(@__DIR__, "durable_document_loader.mjs")
    script = joinpath(@__DIR__, "durable_document_reference.mjs")
    reference = JSON3.read(read(`node --no-warnings --experimental-loader $loader --conditions=source $script`, String), Dict{String, Any})
    mktempdir() do dir
        store = open(D.Store, joinpath(dir, "history.jsonl"))
        chat, other = D.commit!(store) do tx
            chat, other = D.mint!(tx), D.mint!(tx)
            D.put!(tx, D.Conversation(chat, nothing))
            D.put!(tx, D.Conversation(other, nothing))
            chat, other
        end
        entry!(tx, conversation, kind) = D.put!(tx, D.Entry(D.mint!(tx), conversation, kind, nothing))
        before = D.commit!(tx -> entry!(tx, chat, "before"), store)
        first, document = D.commit!(store) do tx
            entry = entry!(tx, chat, "first")
            document = D.mint!(tx)
            D.put!(tx, D.Document(document, chat, Dict("text" => "first")))
            entry, document
        end
        unchanged = D.commit!(tx -> entry!(tx, chat, "unchanged"), store)
        second = D.commit!(store) do tx
            D.put!(tx, D.Document(document, chat, Dict("text" => "second")))
            entry!(tx, chat, "second")
        end
        D.commit!(tx -> D.put!(tx, D.Document(document, chat, Dict("text" => "latest"))), store)
        foreign = D.commit!(tx -> entry!(tx, other, "foreign"), store)
        result = Dict(
            "before" => value(D.snapshot(store, chat, document, before)),
            "first" => value(D.snapshot(store, chat, document, first)),
            "unchanged" => value(D.snapshot(store, chat, document, unchanged)),
            "second" => value(D.snapshot(store, chat, document, second)),
            "latest" => get(store, D.Document, document).value,
            "foreignRejected" => D.snapshot(store, chat, document, foreign) == D.Rejected(:entry_not_visible),
        )
        @test result == reference
        close(store)
    end
end
end

end
