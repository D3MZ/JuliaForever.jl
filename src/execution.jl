module Execution

using Distributed
import ..JuliaForever: emit

function perform end

struct Cancellation
    signal::RemoteChannel
end

Cancellation() = Cancellation(RemoteChannel(() -> Channel{Nothing}(1)))
cancelled(cancellation::Cancellation) = !isopen(cancellation.signal)
cancel!(cancellation::Cancellation) = close(cancellation.signal)

struct Stopped end

abstract type Result end

struct Completed{T} <: Result
    id::String
    attempt::Int
    worker::Int
    value::T
end

struct Failed <: Result
    id::String
    attempt::Int
    worker::Int
    message::String
end

struct Cancelled <: Result
    id::String
    attempt::Int
    worker::Int
end

struct Handle
    id::String
    attempt::Int
    cancellation::Cancellation
    result::Channel{Result}
end

Base.fetch(handle::Handle) = fetch(handle.result)
cancel!(handle::Handle) = cancel!(handle.cancellation)
cancel!(::Nothing) = nothing

struct Request{W}
    work::W
    handle::Handle
end

struct Executor
    queue::Channel{Request}
    tasks::Vector{Task}
end

function run(work, cancellation::Cancellation)
    cancelled(cancellation) && return Stopped()
    perform(work, cancellation)
end

result(handle::Handle, pid::Int, ::Stopped) = Cancelled(handle.id, handle.attempt, pid)
result(handle::Handle, pid::Int, value) = Completed(handle.id, handle.attempt, pid, value)

function dispatch(pid::Int, request::Request)
    handle = request.handle
    try
        cancelled(handle.cancellation) && return Cancelled(handle.id, handle.attempt, pid)
        value = pid == myid() ? run(request.work, handle.cancellation) : remotecall_fetch(run, pid, request.work, handle.cancellation)
        result(handle, pid, value)
    catch exception
        Failed(handle.id, handle.attempt, pid, sprint(showerror, exception, catch_backtrace()))
    end
end

function worker(pid::Int, queue::Channel{Request})
    for request in queue
        put!(request.handle.result, dispatch(pid, request))
    end
end

function Executor(pid::Int, pids::Int...; capacity=length(pids) + 1)
    queue = Channel{Request}(capacity)
    tasks = Task[Threads.@spawn worker(id, queue) for id in (pid, pids...)]
    Executor(queue, tasks)
end

function submit!(executor::Executor, id::AbstractString, attempt::Integer, work; on_handle=nothing)
    handle = Handle(String(id), Int(attempt), Cancellation(), Channel{Result}(1))
    emit(on_handle, handle)
    put!(executor.queue, Request(work, handle))
    handle
end

function Base.close(executor::Executor)
    close(executor.queue)
    foreach(wait, executor.tasks)
    nothing
end

include("execution_conversation.jl")

end
