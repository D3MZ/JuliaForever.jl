module ExecutionCases

using Distributed, JuliaForever
const E = JuliaForever.Execution

struct Value
    value::Int
end

E.perform(work::Value, cancellation::E.Cancellation) = (work.value, myid())

struct Fail end
E.perform(::Fail, cancellation::E.Cancellation) = error("work failed")

struct Gate
    started::RemoteChannel
    release::RemoteChannel
    cooperative::Bool
end

function E.perform(work::Gate, cancellation::E.Cancellation)
    put!(work.started, myid())
    while !isready(work.release)
        work.cooperative && E.cancelled(cancellation) && return E.Stopped()
        sleep(0.01)
    end
    take!(work.release)
    :released
end

struct Crash
    started::RemoteChannel
    release::RemoteChannel
end

function E.perform(work::Crash, cancellation::E.Cancellation)
    put!(work.started, myid())
    take!(work.release)
    exit(42)
end

end
