using Test, JuliaForever, JSON3
import JuliaForever.History as H
import JuliaForever.Conversation as C

mutable struct TreeProvider
    requests::Vector{Any}
end

function JuliaForever.complete(provider::TreeProvider, messages, tools)
    push!(provider.requests, deepcopy(messages))
    Dict("role" => "assistant", "content" => "reply:" * messages[end]["content"])
end

struct BrokenTreeProvider end
JuliaForever.complete(::BrokenTreeProvider, messages, tools) = sqrt(-1)

function tree_inputs(history)
    [entry for entry in H.entries(history)[2:end] if H.decode_event(only(entry.batch)) isa C.Input]
end

function tree_text(agent)
    [message["content"] for message in agent.messages if message["role"] in ("user", "assistant")]
end

@testset "recorded session branches" begin
    store = H.Memory()
    tree = H.Tree(store)
    provider = TreeProvider([])
    agent = Agent(provider, []; history=tree)
    @test respond!(agent, "first") == "reply:first"
    @test respond!(agent, "second") == "reply:second"
    inputs = tree_inputs(tree)
    @test length(inputs) == 2
    original = last(H.entries(tree)).id
    firstturn = inputs[2].parent
    revision = H.snapshot(store).revision
    calls = length(provider.requests)
    @test H.branch!(tree, firstturn) == firstturn
    @test H.snapshot(store).revision == revision
    @test length(provider.requests) == calls
    branched = Agent(provider, []; history=tree)
    @test tree_text(branched) == ["first", "reply:first"]
    @test respond!(branched, "alternative") == "reply:alternative"
    @test tree_text(branched) == ["first", "reply:first", "alternative", "reply:alternative"]
    forked = last(H.entries(tree)).id
    @test forked > original
    @test H.snapshot(tree).revision == forked
    @test H.snapshot(tree).revision > length(H.snapshot(tree).batches)
    @test H.branch!(tree, original) == original
    @test tree_text(Agent(provider, []; history=tree)) == ["first", "reply:first", "second", "reply:second"]
    @test H.branch!(tree, 999999) == H.Rejected(:missing_branch)
    @test tree_text(Agent(provider, []; history=tree)) == ["first", "reply:first", "second", "reply:second"]

    reopened = H.Tree(store)
    @test tree_text(Agent(provider, []; history=reopened)) == ["first", "reply:first", "alternative", "reply:alternative"]
    @test H.branch!(reopened, original) == original
    @test tree_text(Agent(provider, []; history=reopened)) == ["first", "reply:first", "second", "reply:second"]
    entries = H.entries(reopened)
    entries[1].batch[1]["id"] = "modified"
    @test H.entries(reopened)[1].batch[1]["id"] != "modified"
    if haskey(ENV, "PI_SOURCE")
        source = ENV["PI_SOURCE"]
        @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
        script = joinpath(@__DIR__, "tree_history_pi.mjs")
        reference = JSON3.read(read(`node $script $source $(pwd())`, String), Vector{Vector{String}})
        @test tree_text(Agent(provider, []; history=reopened)) == reference[1]
        @test H.branch!(reopened, forked) == forked
        @test tree_text(Agent(provider, []; history=reopened)) == reference[2]
    end
end

@testset "agents on another branch become stale" begin
    store = H.Memory()
    tree = H.Tree(store)
    provider = TreeProvider([])
    agent = Agent(provider, []; history=tree)
    @test respond!(agent, "first") == "reply:first"
    @test respond!(agent, "second") == "reply:second"
    original = last(H.entries(tree)).id
    firstturn = tree_inputs(tree)[2].parent
    @test H.branch!(tree, firstturn) == firstturn
    stale = Agent(provider, []; history=tree)
    @test respond!(stale, "alternative") == "reply:alternative"
    @test H.branch!(tree, original) == original
    count = length(provider.requests)
    @test respond!(stale, "must not run") == H.Rejected(:revision)
    @test length(provider.requests) == count
    @test tree_text(Agent(provider, []; history=tree)) == ["first", "reply:first", "second", "reply:second"]
end

@testset "legacy histories and competing writers" begin
    store = H.Memory()
    provider = TreeProvider([])
    legacy = Agent(provider, []; history=store)
    @test respond!(legacy, "legacy") == "reply:legacy"
    first = H.Tree(store)
    second = H.Tree(store)
    @test tree_text(Agent(provider, []; history=first)) == ["legacy", "reply:legacy"]
    @test respond!(Agent(provider, []; history=first), "next") == "reply:next"
    @test H.snapshot(second) == H.Rejected(:revision)
    @test H.branch!(second, 1) == H.Rejected(:revision)
    @test H.append!(second, H.snapshot(store).revision, Any["stale"]) == H.Rejected(:revision)
    @test tree_text(Agent(provider, []; history=H.Tree(store))) == ["legacy", "reply:legacy", "next", "reply:next"]
end

@testset "SQLite competing branch views" begin
    mktempdir() do dir
        path = joinpath(dir, "tree.sqlite")
        first = H.Tree(open(H.SQLite, path))
        provider = TreeProvider([])
        agent = Agent(provider, []; history=first)
        @test respond!(agent, "first") == "reply:first"
        second = H.Tree(open(H.SQLite, path; create=false))
        stale = Agent(provider, []; history=second)
        @test respond!(agent, "second") == "reply:second"
        count = length(provider.requests)
        @test respond!(stale, "stale") == H.Rejected(:revision)
        @test length(provider.requests) == count
        @test H.snapshot(second) == H.Rejected(:revision)
        close(first)
        close(second)
    end
end

@testset "branching never bypasses an uncertain effect" begin
    store = H.Memory()
    tree = H.Tree(store)
    agent = Agent(BrokenTreeProvider(), []; history=tree)
    @test_throws DomainError respond!(agent, "interrupted")
    @test agent.fault == H.Rejected(:uncertain_effect)
    count = length(H.entries(tree))
    @test H.branch!(tree, 1) == H.Rejected(:uncertain_effect)
    @test length(H.entries(tree)) == count
    @test Agent(BrokenTreeProvider(), []; history=tree).fault == H.Rejected(:uncertain_effect)
    @test JuliaForever.abandon!(agent, "inspected") isa JuliaForever.Kernel.Applied
    @test H.branch!(tree, 1) == 1
end

@testset "invalid branch metadata" begin
    store = H.Memory()
    initial = H.encode_initial(C.State("tree"; automatic=false))
    @test H.append!(store, 0, Any[initial]) == 1
    malformed = Dict("format" => "JuliaForever.SessionTree/1", "parent" => 99, "batch" => Any[H.encode(C.Input(0, "bad"))])
    @test H.append!(store, 1, Any[malformed]) == 2
    @test H.Tree(store) == H.Rejected(:invalid_record)
    @test H.snapshot(store).revision == 2
end

@testset "tree store keeps batch boundaries" begin
    store = H.Memory()
    tree = H.Tree(store)
    @test H.append!(tree, 0, Any["one", "two"]) == 1
    @test H.snapshot(tree).batches == [Any["one", "two"]]
    reopened = H.Tree(store)
    @test reopened isa H.Tree
    @test H.snapshot(reopened).batches == [Any["one", "two"]]
    @test H.branch!(reopened, 1) == H.Rejected(:invalid_record)
    @test H.append!(reopened, 1, Any[]) == H.Rejected(:empty_batch)
end

@testset "journal-backed branches" begin
    if Sys.isunix()
        mktempdir() do dir
            D = JuliaForever.Durable
            path = joinpath(dir, "journal.jsonl")
            store = open(D.Store, path)
            journal = H.create(store)
            id = journal.id
            tree = H.Tree(journal)
            provider = TreeProvider([])
            agent = Agent(provider, []; history=tree)
            @test respond!(agent, "first") == "reply:first"
            @test respond!(agent, "second") == "reply:second"
            parent = tree_inputs(tree)[2].parent
            @test H.branch!(tree, parent) == parent
            @test respond!(Agent(provider, []; history=tree), "branch") == "reply:branch"
            close(tree)
            @test H.snapshot(journal).revision > 0
            close(store)
            reopened = open(D.Store, path)
            restored = H.Tree(H.Journal(reopened, id))
            @test tree_text(Agent(provider, []; history=restored)) == ["first", "reply:first", "branch", "reply:branch"]
            close(restored)
            close(reopened)
        end
    end
end
