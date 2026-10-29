abstract type Handler end
abstract type Phase end

struct Checkpoint
    name::String
    value::Any
end
same(a, b) = typeof(a) === typeof(b) && isequal(a, b)
same(a::AbstractDict, b::AbstractDict) = length(a) == length(b) && all(haskey(b, key) && same(value, b[key]) for (key, value) in a)
same(a::AbstractVector, b::AbstractVector) = length(a) == length(b) && all(same(x, y) for (x, y) in zip(a, b))
Base.:(==)(a::Checkpoint, b::Checkpoint) = a.name == b.name && same(a.value, b.value)

function name end

struct Invocation
    task::Int
    conversation::Int
    phase::Int
    attempt::Int
end

abstract type PhaseResult end
struct Next{T <: Phase} <: PhaseResult
    phase::T
end
struct Complete <: PhaseResult
    value::Any
end
struct Retry <: PhaseResult
    message::String
end
struct Fail <: PhaseResult
    message::String
end

abstract type TaskStatus end
struct Pending <: TaskStatus end
struct Running <: TaskStatus
    cancelled::Bool
end
struct Completed <: TaskStatus
    value::Any
end
struct Failed <: TaskStatus
    reason::Symbol
end
struct Cancelled <: TaskStatus end

struct TaskView
    id::Int
    conversation::Int
    kind::String
    request::Union{Nothing, String}
    input::Any
    checkpoint::Checkpoint
    phase::Int
    attempts::Int
    restarts::Int
    maxattempts::Int
    message::Union{Nothing, String}
    status::TaskStatus
end

mutable struct Scheduler
    store::Store
    lock::ReentrantLock
    active::Int
end

checkpoint(data) = Checkpoint(data["name"], data["value"])
checkpoint(value::Checkpoint) = Dict("name" => value.name, "value" => value.value)

function taskstatus(state)
    value = state["status"]
    value == "pending" && return Pending()
    value == "running" && return Running(state["cancelled"])
    value == "completed" && return Completed(state["result"])
    value == "failed" && return Failed(Symbol(state["reason"]))
    value == "cancelled" && return Cancelled()
    Dict{String, TaskStatus}()[value]
end

function taskview(record::Task)
    state = record.state
    state isa AbstractDict || return nothing
    get(state, "scheduler", nothing) == "JuliaForever.Scheduler/1" || return nothing
    spec = state["spec"]
    TaskView(record.id, record.conversation, spec["kind"], state["request"], spec["input"], checkpoint(state["checkpoint"]), state["phase"], state["attempts"], state["restarts"], spec["maxattempts"], state["message"], taskstatus(state))
end

function Base.open(::Type{Scheduler}, path::AbstractString)
    store = open(Store, path)
    store isa Rejected && return store
    success = false
    try
        records = scan(store, Task)
        result = commit!(store) do tx
            for record in records
                view = taskview(record)
                view === nothing && continue
                view.status isa Running || continue
                state = record.state
                state["restarts"] += 1
                if view.status.cancelled
                    state["status"] = "cancelled"
                elseif view.attempts >= view.maxattempts
                    state["status"] = "failed"
                    state["reason"] = "attempt_limit"
                    state["message"] = "interrupted"
                else
                    state["status"] = "pending"
                    state["message"] = "interrupted"
                end
                put!(tx, record)
            end
            nothing
        end
        result isa Rejected && return result
        scheduler = Scheduler(store, ReentrantLock(), 0)
        success = true
        scheduler
    finally
        success || close(store)
    end
end

function Base.close(scheduler::Scheduler)
    lock(scheduler.lock) do
        scheduler.active > 0 && return Rejected(:busy)
        close(scheduler.store)
    end
end

function Base.get(scheduler::Scheduler, id::Integer)
    record = get(scheduler.store, Task, id)
    record isa Task ? taskview(record) : record
end

function scan(scheduler::Scheduler; conversation::Union{Nothing, Integer}=nothing)
    records = scan(scheduler.store, Task; conversation)
    records isa Rejected && return records
    result = TaskView[]
    for record in records
        view = taskview(record)
        view === nothing || push!(result, view)
    end
    result
end

function enqueue!(scheduler::Scheduler, conversation::Integer, handler::Handler, phase::Phase, input; request::Union{Nothing, AbstractString}=nothing, maxattempts::Integer=3)
    maxattempts > 0 || return Rejected(:invalid_attempt_limit)
    initial = checkpoint(encode(phase))
    spec = JSON3.read(JSON3.write(Dict("kind" => name(handler), "input" => input, "initial" => initial, "maxattempts" => maxattempts)), Dict{String, Any})
    key = isnothing(request) ? nothing : String(request)
    commit!(scheduler.store) do tx
        if key !== nothing
            for record in scan(scheduler.store, Task; conversation)
                view = taskview(record)
                view === nothing && continue
                view.request == key || continue
                return same(record.state["spec"], spec) ? record.id : Rejected(:request_conflict)
            end
        end
        id = mint!(tx)
        state = Dict("scheduler" => "JuliaForever.Scheduler/1", "spec" => spec, "request" => key, "checkpoint" => spec["initial"], "phase" => 1, "attempts" => 0, "restarts" => 0, "message" => nothing, "status" => "pending", "cancelled" => false, "result" => nothing, "reason" => nothing)
        put!(tx, Task(id, conversation, state))
    end
end

function reserve!(scheduler::Scheduler, id::Integer, handler::Handler)
    commit!(scheduler.store) do tx
        record = get(tx, Task, id)
        record === nothing && return Rejected(:task_missing)
        record isa Rejected && return record
        view = taskview(record)
        view === nothing && return Rejected(:not_scheduled)
        view.kind == name(handler) || return Rejected(:handler_mismatch)
        view.status isa Pending || return Rejected(:not_pending)
        record.state["status"] = "running"
        record.state["attempts"] += 1
        result = put!(tx, record)
        result isa Rejected ? result : taskview(get(tx, Task, id))
    end
end

function advance!(state, result::Next)
    next = JSON3.read(JSON3.write(checkpoint(encode(result.phase))), Dict{String, Any})
    same(state["checkpoint"], next) && return advance!(state, Retry("no checkpoint progress"))
    state["checkpoint"] = next
    state["phase"] += 1
    state["attempts"] = 0
    state["status"] = "pending"
    state["message"] = nothing
end

function advance!(state, result::Complete)
    state["status"] = "completed"
    state["result"] = result.value
    state["message"] = nothing
end

function advance!(state, result::Retry)
    state["message"] = result.message
    if state["attempts"] >= state["spec"]["maxattempts"]
        state["status"] = "failed"
        state["reason"] = "attempt_limit"
    else
        state["status"] = "pending"
    end
end

function advance!(state, result::Fail)
    state["status"] = "failed"
    state["reason"] = "handler_failure"
    state["message"] = result.message
end

function step!(scheduler::Scheduler, id::Integer, handler::Handler)
    reserved = lock(scheduler.lock) do
        result = reserve!(scheduler, id, handler)
        result isa TaskView && (scheduler.active += 1)
        result
    end
    reserved isa TaskView || return reserved
    try
        phase = decode(handler, reserved.checkpoint)
        context = Invocation(reserved.id, reserved.conversation, reserved.phase, reserved.attempts)
        outcome = run(handler, phase, reserved.input, context)
        commit!(scheduler.store) do tx
            record = get(tx, Task, id)
            record isa Task || return record
            state = record.state
            if state["cancelled"]
                state["status"] = "cancelled"
            else
                advance!(state, outcome)
            end
            result = put!(tx, record)
            result isa Rejected ? result : taskview(get(tx, Task, id))
        end
    finally
        lock(scheduler.lock) do
            scheduler.active -= 1
        end
    end
end

function cancel!(scheduler::Scheduler, id::Integer)
    commit!(scheduler.store) do tx
        record = get(tx, Task, id)
        record === nothing && return Rejected(:task_missing)
        record isa Rejected && return record
        view = taskview(record)
        view === nothing && return Rejected(:not_scheduled)
        view.status isa Cancelled && return view
        view.status isa Union{Completed, Failed} && return Rejected(:finished)
        state = record.state
        if view.status isa Pending
            state["status"] = "cancelled"
        elseif state["cancelled"]
            return view
        else
            state["cancelled"] = true
        end
        result = put!(tx, record)
        result isa Rejected ? result : taskview(get(tx, Task, id))
    end
end
