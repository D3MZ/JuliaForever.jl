module DurablePolicyForkTests

using Test, JSON3, JuliaForever
import JuliaForever.Durable as D

reason(result) = result isa D.Rejected ? result.reason : nothing

function create!(tx, conversation, kind, key, policy, value)
    id = D.mint!(tx)
    D.put!(tx, D.PolicyDocument(id, conversation, kind, key, policy, Dict("value" => value)))
    id
end

function update!(tx, id, value)
    doc = get(tx, D.PolicyDocument, id)
    D.put!(tx, D.PolicyDocument(doc.id, doc.conversation, doc.kind, doc.key, doc.policy, Dict("value" => value)))
end

function finddoc(store, conversation, kind, key=nothing)
    docs = D.scan(store, D.PolicyDocument; conversation)
    index = findfirst(doc -> doc.kind == kind && doc.key == key, docs)
    index === nothing ? nothing : docs[index]
end

value(::Nothing) = nothing
value(doc::D.Record) = doc.value["value"]

function values(store, conversation)
    Dict("asof" => value(finddoc(store, conversation, "asof")), "current" => value(finddoc(store, conversation, "current")),
         "initial" => value(finddoc(store, conversation, "initial")), "late" => value(finddoc(store, conversation, "late")),
         "empty" => value(finddoc(store, conversation, "family", "")), "keyed" => value(finddoc(store, conversation, "family", "a")))
end
entries(store, conversation) = [entry.value for entry in D.entries(store, conversation)]

# Pi can retire and recreate this address; native retirement is not implemented.
# Exercise the selector against that hypothetical state without persisting it.
function collisioncheck(store, parent, point, old)
    state = deepcopy(store.state)
    delete!(state.records, old.id)
    delete!(state.policies, old.id)
    delete!(state.addresses, (parent, old.kind, old.key))
    id = state.nextid + 1
    D.apply!(state, D.PolicyDocument(id, parent, old.kind, old.key, D.Current(), Dict("value" => "replacement")))
    D.forkplan(state, parent, point) == D.Rejected(:fork_document_address_in_use)
end

if Sys.isunix()
@testset "document fork policies and safety" begin
    mktempdir() do dir
        path = joinpath(dir, "policies.jsonl")
        store = open(D.Store, path)
        root, other = D.commit!(store) do tx
            root, other = D.mint!(tx), D.mint!(tx)
            D.put!(tx, D.Conversation(root, nothing))
            D.put!(tx, D.Conversation(other, nothing))
            D.put!(tx, D.Document(D.mint!(tx), other, "unrelated"))
            root, other
        end
        before = D.commit!(store) do tx
            D.put!(tx, D.Entry(D.mint!(tx), root, "before", "before"))
        end
        point, hidden, asof, current = D.commit!(store) do tx
            point = D.put!(tx, D.Entry(D.mint!(tx), root, "point", "point"))
            asof = create!(tx, root, "asof", nothing, D.AsOf(), "root-at-point")
            current = create!(tx, root, "current", nothing, D.Current(), "current-at-point")
            create!(tx, root, "initial", nothing, D.Initial(), "parent-only")
            create!(tx, root, "family", "", D.AsOf(), "empty-key")
            create!(tx, root, "family", "a", D.AsOf(), "key-a")
            hidden = D.put!(tx, D.Entry(D.mint!(tx), root, "hidden", "hidden"))
            point, hidden, asof, current
        end
        D.commit!(store) do tx
            update!(tx, asof, "root-after")
            update!(tx, current, "current-after")
            create!(tx, root, "late", nothing, D.AsOf(), "late")
        end
        child = D.commit!(tx -> D.fork!(tx, root, point), store)
        early = D.commit!(tx -> D.fork!(tx, root, before), store)
        childasof = finddoc(store, child, "asof")
        childcurrent = finddoc(store, child, "current")
        @test childasof.id != asof && childcurrent.id != current
        childpoint, childhidden = D.commit!(store) do tx
            childpoint = D.put!(tx, D.Entry(D.mint!(tx), child, "child", "child"))
            update!(tx, childasof.id, "child-at-point")
            update!(tx, childcurrent.id, "child-current")
            childhidden = D.put!(tx, D.Entry(D.mint!(tx), child, "child-hidden", "child-hidden"))
            childpoint, childhidden
        end
        D.commit!(tx -> update!(tx, current, "root-newer"), store)
        inherited = D.commit!(tx -> D.fork!(tx, child, point), store)
        nested = D.commit!(tx -> D.fork!(tx, child, childpoint), store)
        actual = Dict("collisionRejected" => collisioncheck(store, child, point, childasof), "child" => values(store, child), "early" => values(store, early), "inherited" => values(store, inherited), "nested" => values(store, nested),
                      "inheritedEntries" => entries(store, inherited), "nestedEntries" => entries(store, nested),
                      "hiddenRejected" => D.commit!(tx -> D.fork!(tx, child, hidden), store) == D.Rejected(:fork_point_missing),
                      "stagedRejected" => D.commit!(store) do tx
                          staged = D.put!(tx, D.Entry(D.mint!(tx), root, "staged", "staged"))
                          D.fork!(tx, root, staged)
                      end == D.Rejected(:fork_point_missing))
        expected = Dict("collisionRejected" => true, "child" => Dict("asof" => "child-at-point", "current" => "child-current", "initial" => nothing, "late" => nothing, "empty" => "empty-key", "keyed" => "key-a"),
                        "early" => Dict("asof" => nothing, "current" => "current-after", "initial" => nothing, "late" => nothing, "empty" => nothing, "keyed" => nothing),
                        "inherited" => Dict("asof" => "root-at-point", "current" => "child-current", "initial" => nothing, "late" => nothing, "empty" => "empty-key", "keyed" => "key-a"),
                        "nested" => Dict("asof" => "child-at-point", "current" => "child-current", "initial" => nothing, "late" => nothing, "empty" => "empty-key", "keyed" => "key-a"),
                        "inheritedEntries" => ["before", "point"], "nestedEntries" => ["before", "point", "child"], "hiddenRejected" => true, "stagedRejected" => true)
        @test actual == expected
        if haskey(ENV, "PI_SOURCE")
            @test readchomp(`git -C $(ENV["PI_SOURCE"]) rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
            loader = joinpath(@__DIR__, "durable_document_loader.mjs")
            script = joinpath(@__DIR__, "durable_policy_forks.mjs")
            reference = JSON3.read(read(`node --no-warnings --experimental-loader $loader --conditions=source $script`, String), Dict{String, Any})
            @test actual == reference
        end
        @test entries(store, child) == ["before", "point", "child", "child-hidden"]
        @test value(get(store, D.PolicyDocument, asof)) == "root-after"
        @test value(D.snapshot(store, root, asof, point)) == "root-at-point"
        @test value(D.snapshot(store, root, current, point)) == "current-at-point"
        detached = D.snapshot(store, root, asof, point)
        detached.value["value"] = "mutated read"
        @test value(D.snapshot(store, root, asof, point)) == "root-at-point"
        @test D.snapshot(store, root, finddoc(store, root, "late").id, before) === nothing
        @test D.snapshot(store, child, childasof.id, point) == D.Rejected(:entry_not_visible)
        @test only(D.scan(store, D.Document; conversation=other)).value == "unrelated"
        saved = actual
        close(store)
        store = open(D.Store, path)
        @test values(store, inherited) == saved["inherited"]
        @test values(store, nested) == saved["nested"]
        @test entries(store, inherited) == saved["inheritedEntries"]
        @test entries(store, nested) == saved["nestedEntries"]
        @test get(store, D.Conversation, inherited).parent == (child, point)
        @test finddoc(store, inherited, "asof").id != asof
        close(store)
    end
end

@testset "document fork admission and rollback" begin
    mktempdir() do dir
        store = open(D.Store, joinpath(dir, "admission.jsonl"))
        root, other, point, source = D.commit!(store) do tx
            root, other = D.mint!(tx), D.mint!(tx)
            D.put!(tx, D.Conversation(root, nothing))
            D.put!(tx, D.Conversation(other, nothing))
            point = D.put!(tx, D.Entry(D.mint!(tx), root, "point", "point"))
            source = create!(tx, root, "same", nothing, D.AsOf(), "source")
            create!(tx, root, "same", "", D.AsOf(), "empty-key")
            root, other, point, source
        end
        before = D.revision(store)
        @test reason(D.commit!(tx -> create!(tx, root, "same", nothing, D.Current(), "duplicate"), store)) == :document_address_in_use
        @test reason(D.commit!(tx -> D.put!(tx, D.PolicyDocument(source, root, "same", "changed", D.AsOf(), nothing)), store)) == :immutable
        @test reason(D.commit!(tx -> D.put!(tx, D.PolicyDocument(source, other, "same", nothing, D.AsOf(), nothing)), store)) == :immutable
        @test reason(D.commit!(tx -> D.put!(tx, D.PolicyDocument(source, root, "same", nothing, D.Current(), nothing)), store)) == :immutable
        @test reason(D.commit!(tx -> D.put!(tx, D.Document(source, root, "wrong record type")), store)) == :id_in_use
        @test reason(D.commit!(tx -> D.put!(tx, D.Conversation(D.mint!(tx), nothing, (root, point))), store)) == :fork_documents_unsupported
        @test D.revision(store) == before
        for order in (:before, :after)
            result = D.commit!(store) do tx
                order == :before && create!(tx, root, "new-current", nothing, D.Current(), "staged")
                D.fork!(tx, root, point)
                order == :after && create!(tx, root, "new-current", nothing, D.Current(), "staged")
                :ignored
            end
            @test reason(result) == :fork_source_modified
            @test finddoc(store, root, "new-current") === nothing
            @test D.revision(store) == before
        end
        for order in (:before, :after)
            child = Ref{Any}(nothing)
            result = D.commit!(store) do tx
                order == :before && update!(tx, source, "staged")
                child[] = D.fork!(tx, root, point)
                order == :after && update!(tx, source, "staged")
                :ignored
            end
            @test reason(result) == :fork_source_modified
            @test child[] isa D.Rejected ? reason(child[]) == :fork_source_modified : get(store, D.Conversation, child[]) === nothing
            @test value(get(store, D.PolicyDocument, source)) == "source"
            @test D.revision(store) == before
        end
        for order in (:before, :after)
            result = D.commit!(store) do tx
                order == :before && D.put!(tx, D.Document(D.mint!(tx), root, "staged opaque"))
                D.fork!(tx, root, point)
                order == :after && D.put!(tx, D.Document(D.mint!(tx), root, "staged opaque"))
                :ignored
            end
            @test reason(result) == :fork_documents_unsupported
            @test isempty(D.scan(store, D.Document; conversation=root))
            @test D.revision(store) == before
        end
        child = Ref(0)
        result = D.commit!(store) do tx
            child[] = D.fork!(tx, root, point)
            D.put!(tx, D.Document(D.mint!(tx), 999999, "failure"))
            :ignored
        end
        @test reason(result) == :conversation_missing
        @test get(store, D.Conversation, child[]) === nothing
        @test D.revision(store) == before
        child = D.commit!(store) do tx
            child = D.fork!(tx, root, point)
            D.put!(tx, D.Document(D.mint!(tx), other, "unrelated"))
            child
        end
        @test child isa Int
        @test value(finddoc(store, child, "same")) == "source"
        @test value(finddoc(store, child, "same", "")) == "empty-key"
        @test allunique(doc.id for doc in D.scan(store, D.PolicyDocument))
        before = D.revision(store)
        result = D.commit!(store) do tx
            D.fork!(tx, child, point)
            update!(tx, source, "changed ancestor")
        end
        @test reason(result) == :fork_source_modified
        @test value(get(store, D.PolicyDocument, source)) == "source"
        @test D.revision(store) == before
        D.commit!(tx -> D.put!(tx, D.Document(D.mint!(tx), root, "opaque")), store)
        before = D.revision(store)
        @test reason(D.commit!(tx -> D.fork!(tx, child, point), store)) == :fork_documents_unsupported
        @test reason(D.commit!(tx -> D.fork!(tx, root, point), store)) == :fork_documents_unsupported
        @test D.revision(store) == before
        close(store)
    end
end
end

end
