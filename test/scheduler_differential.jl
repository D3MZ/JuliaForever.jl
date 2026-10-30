using Test, JuliaForever, JSON3
import JuliaForever.Durable as D

struct NapPhase <: D.Phase
    value::Int
end
struct NapHandler <: D.Handler
    runs::Base.RefValue{Int}
end
D.name(::NapHandler) = "nap"
D.encode(phase::NapPhase) = D.Checkpoint(phase.value == 1 ? "start" : "after", phase.value)
D.decode(::NapHandler, checkpoint::D.Checkpoint) = NapPhase(checkpoint.value)
function Base.run(handler::NapHandler, phase::NapPhase, input, context::D.Invocation)
    phase.value == 1 && return D.Sleep(NapPhase(2), 2000)
    handler.runs[] += 1
    D.Complete("ok")
end

function sleepview(view)
    Dict("status" => "sleeping", "until" => view.status.until, "phase" => view.checkpoint.name, "value" => view.checkpoint.value)
end

@testset "Pi durable sleep" begin
    source = ENV["PI_SOURCE"]
    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    oracle = JSON3.read(read(`node --conditions=source $(joinpath(@__DIR__, "scheduler_reference.mjs"))`, String), Dict{String, Any})
    @test isdefined(D, :Sleep)
    mktempdir() do dir
        clock = Ref(1000)
        path = joinpath(dir, "tasks.jsonl")
        scheduler = open(D.Scheduler, path; now=() -> clock[])
        convo = D.commit!(scheduler.store) do tx
            id = D.mint!(tx)
            D.put!(tx, D.Conversation(id, nothing))
            id
        end
        runs = Ref(0)
        handler = NapHandler(runs)
        id = D.enqueue!(scheduler, convo, handler, NapPhase(1), nothing; maxattempts=1)
        first = D.step!(scheduler, id, handler)
        @test first.status isa D.Sleeping
        @test sleepview(first) == oracle["first"]
        @test (first.phase, first.attempts, first.restarts) == (2, 0, 0)
        close(scheduler)

        scheduler = open(D.Scheduler, path; now=() -> clock[])
        reopened = get(scheduler, id)
        @test reopened.status isa D.Sleeping
        @test sleepview(reopened) == oracle["reopened"]
        @test reopened.restarts == 0
        clock[] = 1999
        @test D.step!(scheduler, id, handler).reason == :sleeping
        early = sleepview(get(scheduler, id))
        early["runs"] = runs[]
        @test early == oracle["early"]
        clock[] = 2000
        result = D.step!(scheduler, id, handler)
        @test result.status isa D.Completed
        @test Dict("status" => "completed", "result" => result.status.value, "runs" => runs[]) == oracle["due"]
        close(scheduler)
    end
end
