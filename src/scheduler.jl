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
abstract type Running <: TaskStatus end
struct Active <: Running end
struct Cancelling <: Running end
struct Completed <: TaskStatus
    value::Any
end
struct Failed <: TaskStatus
    reason::Symbol
end
struct Cancelled <: TaskStatus end

Running(cancelled::Bool) = cancelled ? Cancelling() : Active()
cancelled(::Active) = false
cancelled(::Cancelling) = true

function Base.getproperty(status::Running, name::Symbol)
    name === :cancelled && return cancelled(status)
    getfield(status, name)
end

Base.propertynames(::Running, private::Bool=false) = (:cancelled,)

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

taskview(record) = record

recover!(tx, record::Task, ::Nothing) = nothing
recover!(tx, record::Task, view::TaskView) = recover!(tx, record, view, view.status)
recover!(tx, record::Task, view::TaskView, ::TaskStatus) = nothing

function recover!(tx, record::Task, view::TaskView, status::Running)
    state = record.state
    state["restarts"] += 1
    recover!(state, view, status)
    put!(tx, record)
    nothing
end

recover!(state::AbstractDict, view::TaskView, ::Cancelling) = (state["status"] = "cancelled"; nothing)

function recover!(state::AbstractDict, view::TaskView, ::Active)
    if view.attempts >= view.maxattempts
        state["status"] = "failed"
        state["reason"] = "attempt_limit"
    else
        state["status"] = "pending"
    end
    state["message"] = "interrupted"
    nothing
end

function Base.open(::Type{Scheduler}, path::AbstractString)
    store = open(Store, path)
    store isa Rejected && return store
    success = false
    try
        records = scan(store, Task)
        result = commit!(store) do tx
            for record in records
                recover!(tx, record, taskview(record))
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

Base.get(scheduler::Scheduler, id::Integer) = taskview(get(scheduler.store, Task, id))

taskviews(rejected::Rejected) = rejected
add!(views::Vector{TaskView}, ::Nothing) = nothing
add!(views::Vector{TaskView}, view::TaskView) = (push!(views, view); nothing)

function taskviews(records::AbstractVector{<:Task})
    result = TaskView[]
    for record in records
        add!(result, taskview(record))
    end
    result
end

scan(scheduler::Scheduler; conversation::Union{Nothing, Integer}=nothing) = taskviews(scan(scheduler.store, Task; conversation))
taskview(tx::Transaction, id::Integer, rejected::Rejected) = rejected
taskview(tx::Transaction, id::Integer, result::Integer) = taskview(get(tx, Task, id))

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
        reserve!(tx, id, handler, get(tx, Task, id))
    end
end

reserve!(tx::Transaction, id::Integer, handler::Handler, ::Nothing) = Rejected(:task_missing)
reserve!(tx::Transaction, id::Integer, handler::Handler, rejected::Rejected) = rejected
reserve!(tx::Transaction, id::Integer, handler::Handler, record::Task) = reserve!(tx, id, handler, record, taskview(record))
reserve!(tx::Transaction, id::Integer, handler::Handler, record::Task, ::Nothing) = Rejected(:not_scheduled)

function reserve!(tx::Transaction, id::Integer, handler::Handler, record::Task, view::TaskView)
    view.kind == name(handler) || return Rejected(:handler_mismatch)
    reserve!(tx, id, record, view.status)
end

reserve!(tx::Transaction, id::Integer, record::Task, ::TaskStatus) = Rejected(:not_pending)

function reserve!(tx::Transaction, id::Integer, record::Task, ::Pending)
    record.state["status"] = "running"
    record.state["attempts"] += 1
    taskview(tx, id, put!(tx, record))
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

advance!(state, result, ::Active) = advance!(state, result)
advance!(state, result, ::Cancelling) = (state["status"] = "cancelled"; nothing)

begin!(scheduler::Scheduler, result) = result

function begin!(scheduler::Scheduler, view::TaskView)
    scheduler.active += 1
    view
end

function step!(scheduler::Scheduler, id::Integer, handler::Handler)
    reserved = lock(scheduler.lock) do
        begin!(scheduler, reserve!(scheduler, id, handler))
    end
    step!(scheduler, id, handler, reserved)
end

step!(scheduler::Scheduler, id::Integer, handler::Handler, result) = result

function step!(scheduler::Scheduler, id::Integer, handler::Handler, reserved::TaskView)
    try
        phase = decode(handler, reserved.checkpoint)
        context = Invocation(reserved.id, reserved.conversation, reserved.phase, reserved.attempts)
        outcome = run(handler, phase, reserved.input, context)
        commit!(scheduler.store) do tx
            step!(tx, id, outcome, get(tx, Task, id))
        end
    finally
        lock(scheduler.lock) do
            scheduler.active -= 1
        end
    end
end

step!(tx::Transaction, id::Integer, outcome, result) = result

function step!(tx::Transaction, id::Integer, outcome, record::Task)
    state = record.state
    advance!(state, outcome, Running(state["cancelled"]))
    taskview(tx, id, put!(tx, record))
end

function cancel!(scheduler::Scheduler, id::Integer)
    commit!(scheduler.store) do tx
        cancel!(tx, id, get(tx, Task, id))
    end
end

cancel!(tx::Transaction, id::Integer, ::Nothing) = Rejected(:task_missing)
cancel!(tx::Transaction, id::Integer, rejected::Rejected) = rejected
cancel!(tx::Transaction, id::Integer, record::Task) = cancel!(tx, id, record, taskview(record))
cancel!(tx::Transaction, id::Integer, record::Task, ::Nothing) = Rejected(:not_scheduled)
cancel!(tx::Transaction, id::Integer, record::Task, view::TaskView) = cancel!(tx, id, record, view, view.status)
cancel!(tx::Transaction, id::Integer, record::Task, view::TaskView, ::Union{Cancelled, Cancelling}) = view
cancel!(tx::Transaction, id::Integer, record::Task, view::TaskView, ::Union{Completed, Failed}) = Rejected(:finished)

function cancel!(tx::Transaction, id::Integer, record::Task, view::TaskView, ::Pending)
    record.state["status"] = "cancelled"
    taskview(tx, id, put!(tx, record))
end

function cancel!(tx::Transaction, id::Integer, record::Task, view::TaskView, ::Active)
    record.state["cancelled"] = true
    taskview(tx, id, put!(tx, record))
end
