using Test, JuliaForever
import JuliaForever.Durable as D

struct TestHandler <: D.Handler end
struct TestPhase <: D.Phase
    value::Int
end
D.name(::TestHandler) = "test"
D.encode(phase::TestPhase) = D.Checkpoint("test", phase.value)
D.decode(::TestHandler, checkpoint::D.Checkpoint) = TestPhase(checkpoint.value)
Base.run(::TestHandler, phase::TestPhase, input, context::D.Invocation) = phase.value == 1 ? D.Next(TestPhase(2)) : D.Complete(Dict("input" => input, "attempt" => context.attempt, "phase" => context.phase))

struct OtherHandler <: D.Handler end
D.name(::OtherHandler) = "other"

struct RetryHandler <: D.Handler end
D.name(::RetryHandler) = "retry"
D.decode(::RetryHandler, checkpoint::D.Checkpoint) = TestPhase(checkpoint.value)
Base.run(::RetryHandler, phase::TestPhase, input, context::D.Invocation) = context.attempt < input ? D.Retry("try again") : D.Complete(context.attempt)

struct NoProgressHandler <: D.Handler end
D.name(::NoProgressHandler) = "no-progress"
D.decode(::NoProgressHandler, checkpoint::D.Checkpoint) = TestPhase(checkpoint.value)
Base.run(::NoProgressHandler, phase::TestPhase, input, context::D.Invocation) = D.Next(phase)

struct FailingHandler <: D.Handler end
D.name(::FailingHandler) = "fail"
D.decode(::FailingHandler, checkpoint::D.Checkpoint) = TestPhase(checkpoint.value)
Base.run(::FailingHandler, ::TestPhase, input, ::D.Invocation) = D.Fail(input)

struct HeldHandler <: D.Handler
    entered::Channel{D.Invocation}
    resume::Channel{Nothing}
end
D.name(::HeldHandler) = "held"
D.decode(::HeldHandler, checkpoint::D.Checkpoint) = TestPhase(checkpoint.value)
function Base.run(handler::HeldHandler, ::TestPhase, input, context::D.Invocation)
    put!(handler.entered, context)
    take!(handler.resume)
    D.Complete(input)
end

struct CrashingHandler <: D.Handler
    marker::String
end
D.name(::CrashingHandler) = "crash"
D.decode(::CrashingHandler, checkpoint::D.Checkpoint) = TestPhase(checkpoint.value)
function Base.run(handler::CrashingHandler, ::TestPhase, input, context::D.Invocation)
    open(handler.marker, "a") do io
        println(io, "$(context.task):$(context.phase):$(context.attempt)")
    end
    D.Complete(input)
end

function conversation(scheduler)
    D.commit!(scheduler.store) do tx
        id = D.mint!(tx)
        D.put!(tx, D.Conversation(id, nothing))
        id
    end
end

if Sys.isunix()
@testset "typed durable phases and admission" begin
    mktempdir() do dir
        path = joinpath(dir, "tasks.jsonl")
        scheduler = open(D.Scheduler, path)
        @test open(D.Scheduler, path).reason == :locked
        convo = conversation(scheduler)
        other = conversation(scheduler)
        input = Dict("message" => "hello")
        id = D.enqueue!(scheduler, convo, TestHandler(), TestPhase(1), input; request="one", maxattempts=2)
        @test id isa Int
        input["message"] = "changed"
        @test D.enqueue!(scheduler, convo, TestHandler(), TestPhase(1), Dict("message" => "hello"); request="one", maxattempts=2) == id
        @test D.enqueue!(scheduler, convo, TestHandler(), TestPhase(1), Dict("message" => "different"); request="one", maxattempts=2).reason == :request_conflict
        @test D.enqueue!(scheduler, convo, TestHandler(), TestPhase(2), Dict("message" => "hello"); request="one", maxattempts=2).reason == :request_conflict
        @test D.enqueue!(scheduler, convo, TestHandler(), TestPhase(1), Dict("message" => "hello"); request="one", maxattempts=3).reason == :request_conflict
        @test D.enqueue!(scheduler, other, TestHandler(), TestPhase(1), "other"; request="one") != id
        boolid = D.enqueue!(scheduler, other, TestHandler(), TestPhase(1), Dict("value" => true); request="typed")
        @test D.enqueue!(scheduler, other, TestHandler(), TestPhase(1), Dict("value" => 1); request="typed").reason == :request_conflict
        @test get(scheduler, boolid).input["value"] === true
        @test D.enqueue!(scheduler, 999, TestHandler(), TestPhase(1), nothing).reason == :conversation_missing
        @test D.enqueue!(scheduler, convo, TestHandler(), TestPhase(1), nothing; maxattempts=0).reason == :invalid_attempt_limit
        @test D.step!(scheduler, id, OtherHandler()).reason == :handler_mismatch
        @test get(scheduler, id).status isa D.Pending
        first = D.step!(scheduler, id, TestHandler())
        @test first.status isa D.Pending
        @test first.checkpoint == D.Checkpoint("test", 2)
        @test (first.phase, first.attempts, first.restarts) == (2, 0, 0)
        close(scheduler)
        scheduler = open(D.Scheduler, path)
        saved = get(scheduler, id)
        @test saved.input == Dict("message" => "hello")
        saved.input["message"] = "mutated view"
        @test get(scheduler, id).input == Dict("message" => "hello")
        @test saved.checkpoint == D.Checkpoint("test", 2)
        result = D.step!(scheduler, id, TestHandler())
        @test result.status isa D.Completed
        @test result.status.value == Dict("input" => Dict("message" => "hello"), "attempt" => 1, "phase" => 2)
        @test D.step!(scheduler, id, TestHandler()).reason == :not_pending
        @test D.cancel!(scheduler, id).reason == :finished
        @test [task.id for task in D.scan(scheduler; conversation=convo)] == [id]
        close(scheduler)
        scheduler = open(D.Scheduler, path)
        @test get(scheduler, id).status isa D.Completed
        @test get(scheduler, id).status.value["phase"] == 2
        @test D.enqueue!(scheduler, convo, TestHandler(), TestPhase(1), Dict("message" => "hello"); request="one", maxattempts=2) == id
        close(scheduler)
    end
end

@testset "bounded explicit retries" begin
    mktempdir() do dir
        scheduler = open(D.Scheduler, joinpath(dir, "tasks.jsonl"))
        convo = conversation(scheduler)
        id = D.enqueue!(scheduler, convo, RetryHandler(), TestPhase(1), 2; maxattempts=2)
        one = D.step!(scheduler, id, RetryHandler())
        @test one.status isa D.Pending
        @test (one.attempts, one.phase) == (1, 1)
        @test one.message == "try again"
        two = D.step!(scheduler, id, RetryHandler())
        @test two.status isa D.Completed && two.status.value == 2
        id = D.enqueue!(scheduler, convo, RetryHandler(), TestPhase(1), 3; maxattempts=2)
        D.step!(scheduler, id, RetryHandler())
        failed = D.step!(scheduler, id, RetryHandler())
        @test failed.status isa D.Failed
        @test failed.status.reason == :attempt_limit
        @test failed.message == "try again"
        id = D.enqueue!(scheduler, convo, NoProgressHandler(), TestPhase(1), nothing; maxattempts=2)
        same = D.step!(scheduler, id, NoProgressHandler())
        @test same.status isa D.Pending
        @test (same.phase, same.attempts, same.message) == (1, 1, "no checkpoint progress")
        exhausted = D.step!(scheduler, id, NoProgressHandler())
        @test exhausted.status isa D.Failed && exhausted.status.reason == :attempt_limit
        id = D.enqueue!(scheduler, convo, FailingHandler(), TestPhase(1), "expected")
        failed = D.step!(scheduler, id, FailingHandler())
        @test failed.status isa D.Failed && failed.status.reason == :handler_failure
        @test failed.message == "expected"
        close(scheduler)
    end
end

@testset "cancellation and serialized reservation" begin
    mktempdir() do dir
        scheduler = open(D.Scheduler, joinpath(dir, "tasks.jsonl"))
        convo = conversation(scheduler)
        handler = HeldHandler(Channel{D.Invocation}(1), Channel{Nothing}(1))
        id = D.enqueue!(scheduler, convo, handler, TestPhase(1), "done")
        worker = Threads.@spawn D.step!(scheduler, id, handler)
        context = take!(handler.entered)
        @test (context.task, context.phase, context.attempt) == (id, 1, 1)
        @test get(scheduler, id).status isa D.Running
        @test D.step!(scheduler, id, handler).reason == :not_pending
        @test close(scheduler).reason == :busy
        marked = D.cancel!(scheduler, id)
        @test marked.status isa D.Running && marked.status.cancelled
        @test D.cancel!(scheduler, id).status.cancelled
        put!(handler.resume, nothing)
        @test fetch(worker).status isa D.Cancelled
        @test D.cancel!(scheduler, id).status isa D.Cancelled
        @test D.step!(scheduler, id, handler).reason == :not_pending
        pending = D.enqueue!(scheduler, convo, handler, TestPhase(1), nothing)
        @test D.cancel!(scheduler, pending).status isa D.Cancelled
        close(scheduler)
    end
end

@testset "abrupt process recovery and effect boundary" begin
    mktempdir() do dir
        path = joinpath(dir, "tasks.jsonl")
        marker = joinpath(dir, "effects.txt")
        scheduler = open(D.Scheduler, path)
        convo = conversation(scheduler)
        id = D.enqueue!(scheduler, convo, CrashingHandler(marker), TestPhase(1), "ok"; maxattempts=2)
        close(scheduler)
        code = """
            using JuliaForever
            import JuliaForever.Durable as D
            struct Crash <: D.Handler end
            struct Work <: D.Phase end
            D.name(::Crash) = "crash"
            D.decode(::Crash, ::D.Checkpoint) = Work()
            function Base.run(::Crash, ::Work, input, context::D.Invocation)
                open(ARGS[2], "a") do io
                    println(io, "\$(context.task):\$(context.phase):\$(context.attempt)")
                end
                ccall(:_exit, Cvoid, (Cint,), 0)
            end
            scheduler = open(D.Scheduler, ARGS[1])
            D.step!(scheduler, parse(Int, ARGS[3]), Crash())
        """
        run(`$(Base.julia_cmd()) --startup-file=no --project=$(dirname(@__DIR__)) -e $code $path $marker $id`)
        scheduler = open(D.Scheduler, path)
        recovered = get(scheduler, id)
        @test recovered.status isa D.Pending
        @test (recovered.phase, recovered.attempts, recovered.restarts) == (1, 1, 1)
        @test recovered.message == "interrupted"
        finished = D.step!(scheduler, id, CrashingHandler(marker))
        @test finished.status isa D.Completed && finished.status.value == "ok"
        @test readlines(marker) == ["$id:1:1", "$id:1:2"]
        close(scheduler)
    end
end
else
@testset "scheduler unsupported platform" begin
    mktempdir() do dir
        @test open(D.Scheduler, joinpath(dir, "tasks.jsonl")).reason == :unsupported_platform
    end
end
end

struct ThrowingHandler <: D.Handler end
D.name(::ThrowingHandler) = "throwing"
D.decode(::ThrowingHandler, checkpoint::D.Checkpoint) = TestPhase(checkpoint.value)
Base.run(::ThrowingHandler, ::TestPhase, input, context::D.Invocation) = error("unexpected handler failure")

if Sys.isunix()
@testset "concurrent requests and recovery limits" begin
    mktempdir() do dir
        path = joinpath(dir, "tasks.jsonl")
        scheduler = open(D.Scheduler, path)
        convo = conversation(scheduler)
        ids = Vector{Int}(undef, 24)
        @sync for i in eachindex(ids)
            Threads.@spawn ids[i] = D.enqueue!(scheduler, convo, TestHandler(), TestPhase(1), "same"; request="shared")
        end
        @test all(==(first(ids)), ids)
        @test length(D.scan(scheduler; conversation=convo)) == 1
        @test D.enqueue!(scheduler, convo, TestHandler(), TestPhase(1), "same") != first(ids)
        unknown = D.commit!(scheduler.store) do tx
            id = D.mint!(tx)
            D.put!(tx, D.Task(id, convo, Dict("status" => "pending")))
            id
        end
        @test get(scheduler, unknown) === nothing
        @test D.step!(scheduler, unknown, TestHandler()).reason == :not_scheduled
        @test D.cancel!(scheduler, unknown).reason == :not_scheduled
        @test D.step!(scheduler, 999, TestHandler()).reason == :task_missing
        @test D.cancel!(scheduler, 999).reason == :task_missing
        id = D.enqueue!(scheduler, convo, ThrowingHandler(), TestPhase(1), nothing; maxattempts=2)
        @test_throws ErrorException D.step!(scheduler, id, ThrowingHandler())
        @test get(scheduler, id).status isa D.Running
        close(scheduler)
        scheduler = open(D.Scheduler, path)
        recovered = get(scheduler, id)
        @test recovered.status isa D.Pending
        @test (recovered.attempts, recovered.restarts) == (1, 1)
        @test_throws ErrorException D.step!(scheduler, id, ThrowingHandler())
        close(scheduler)
        scheduler = open(D.Scheduler, path)
        failed = get(scheduler, id)
        @test failed.status isa D.Failed && failed.status.reason == :attempt_limit
        @test (failed.attempts, failed.restarts, failed.message) == (2, 2, "interrupted")
        @test D.step!(scheduler, id, ThrowingHandler()).reason == :not_pending
        close(scheduler)
        @test get(scheduler, id).reason == :closed
        @test D.enqueue!(scheduler, convo, TestHandler(), TestPhase(1), nothing).reason == :closed
    end
end

@testset "cancel intent survives process exit" begin
    mktempdir() do dir
        path = joinpath(dir, "tasks.jsonl")
        marker = joinpath(dir, "effect.txt")
        scheduler = open(D.Scheduler, path)
        convo = conversation(scheduler)
        id = D.enqueue!(scheduler, convo, CrashingHandler(marker), TestPhase(1), nothing; maxattempts=1)
        close(scheduler)
        code = """
            using JuliaForever
            import JuliaForever.Durable as D
            struct Crash <: D.Handler end
            struct Work <: D.Phase end
            const CURRENT = Ref{Any}()
            D.name(::Crash) = "crash"
            D.decode(::Crash, ::D.Checkpoint) = Work()
            function Base.run(::Crash, ::Work, input, context::D.Invocation)
                D.cancel!(CURRENT[], context.task)
                write(ARGS[2], "effect after cancellation request")
                ccall(:_exit, Cvoid, (Cint,), 0)
            end
            CURRENT[] = open(D.Scheduler, ARGS[1])
            D.step!(CURRENT[], parse(Int, ARGS[3]), Crash())
        """
        run(`$(Base.julia_cmd()) --startup-file=no --project=$(dirname(@__DIR__)) -e $code $path $marker $id`)
        scheduler = open(D.Scheduler, path)
        recovered = get(scheduler, id)
        @test recovered.status isa D.Cancelled
        @test recovered.restarts == 1
        @test read(marker, String) == "effect after cancellation request"
        @test D.step!(scheduler, id, CrashingHandler(marker)).reason == :not_pending
        close(scheduler)
    end
end
end
