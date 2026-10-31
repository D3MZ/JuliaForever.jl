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
