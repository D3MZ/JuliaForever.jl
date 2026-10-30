using Test, JuliaForever, JSON3
import JuliaForever.Durable as D
struct OwnerPhase <: D.Phase end
struct OwnerHandler <: D.Handler end
D.name(::OwnerHandler) = "owner"
D.encode(::OwnerPhase) = D.Checkpoint("work", nothing)
D.decode(::OwnerHandler, ::D.Checkpoint) = OwnerPhase()
Base.run(::OwnerHandler, ::OwnerPhase, input, context::D.Invocation) = D.Complete(nothing)
@testset "Pi task ownership cancellation" begin
    source = ENV["PI_SOURCE"]
    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    oracle = JSON3.read(read(`node --conditions=source $(joinpath(@__DIR__, "ownership_reference.mjs"))`, String), Dict{String, Any})
    mktempdir() do dir
        path = joinpath(dir, "tasks")
        s = open(D.Scheduler, path)
        convo = D.commit!(s.store) do tx
            id = D.mint!(tx); D.put!(tx, D.Conversation(id, nothing)); id
        end
        h = OwnerHandler()
        parent = D.enqueue!(s, convo, h, OwnerPhase(), nothing)
        child = D.enqueue!(s, convo, h, OwnerPhase(), nothing; owner=parent)
        grandchild = D.enqueue!(s, convo, h, OwnerPhase(), nothing; owner=child)
        other = D.enqueue!(s, convo, h, OwnerPhase(), nothing)
        close(s); s = open(D.Scheduler, path)
        D.cancel!(s, parent)
        statuses = [get(s, id).status isa D.Cancelled ? "aborted" : "live" for id in (parent, child, grandchild)]
        @test statuses == oracle["statuses"]
        @test (get(s, other).status isa D.Cancelled) == oracle["other"]
        close(s); s = open(D.Scheduler, path)
        @test all(get(s, id).status isa D.Cancelled for id in (parent, child, grandchild))
        close(s)
    end
end
