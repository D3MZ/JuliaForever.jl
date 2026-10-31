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

struct ThrowingHandler <: D.Handler end
D.name(::ThrowingHandler) = "throwing"
D.decode(::ThrowingHandler, checkpoint::D.Checkpoint) = TestPhase(checkpoint.value)
Base.run(::ThrowingHandler, ::TestPhase, input, context::D.Invocation) = error("unexpected handler failure")

struct SleepHandler <: D.Handler
    until::UInt64
end
D.name(::SleepHandler) = "sleep"
D.decode(::SleepHandler, checkpoint::D.Checkpoint) = TestPhase(checkpoint.value)
Base.run(handler::SleepHandler, phase::TestPhase, input, context::D.Invocation) = phase.value == 1 ? D.Sleep(TestPhase(2), handler.until) : D.Complete(input)

struct SameSleepHandler <: D.Handler end
D.name(::SameSleepHandler) = "same-sleep"
D.decode(::SameSleepHandler, checkpoint::D.Checkpoint) = TestPhase(checkpoint.value)
Base.run(::SameSleepHandler, phase::TestPhase, input, context::D.Invocation) = context.phase == 1 ? D.Sleep(phase, 0) : D.Complete(input)

struct HeldSleepHandler <: D.Handler
    entered::Channel{Nothing}
    resume::Channel{Nothing}
end
D.name(::HeldSleepHandler) = "held-sleep"
D.decode(::HeldSleepHandler, checkpoint::D.Checkpoint) = TestPhase(checkpoint.value)
function Base.run(handler::HeldSleepHandler, phase::TestPhase, input, context::D.Invocation)
    put!(handler.entered, nothing)
    take!(handler.resume)
    D.Sleep(TestPhase(2), input)
end

if Sys.isunix() && haskey(ENV, "PI_SOURCE")
    include("scheduler_differential.jl")
    include("ownership_differential.jl")
end

struct JoinHandler <: D.Handler end
D.name(::JoinHandler) = "join"
D.decode(::JoinHandler, checkpoint::D.Checkpoint) = TestPhase(checkpoint.value)
Base.run(::JoinHandler, phase::TestPhase, input, ::D.Invocation) = phase.value == 1 ? D.Join(TestPhase(2), input) : D.Complete("joined")
