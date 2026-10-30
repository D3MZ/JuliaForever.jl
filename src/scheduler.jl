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
struct Sleep{T <: Phase} <: PhaseResult
    phase::T
    until::UInt64
end
Sleep(phase::T, until::Integer) where {T <: Phase} = Sleep{T}(phase, UInt64(until))
struct Join{T <: Phase} <: PhaseResult
    phase::T
    on::Vector{Int}
end
Join(phase::T, on::AbstractVector) where {T <: Phase} = Join{T}(phase, Int[on...])
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
struct Sleeping <: TaskStatus
    until::UInt64
end
struct Waiting <: TaskStatus
    on::Vector{Int}
end
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

struct TaskView{S <: TaskStatus}
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
    status::S
end

mutable struct Scheduler{F}
    store::Store
    lock::ReentrantLock
    active::Int
    now::F
    changed::Threads.Condition
end

checkpoint(data) = Checkpoint(data["name"], data["value"])
checkpoint(value::Checkpoint) = Dict("name" => value.name, "value" => value.value)

const taskstatuses = Dict("pending" => Pending, "sleeping" => Sleeping, "waiting" => Waiting, "running" => Running, "completed" => Completed, "failed" => Failed, "cancelled" => Cancelled)
taskstatus(state) = taskstatus(taskstatuses[state["status"]], state)
taskstatus(::Type{Pending}, state) = Pending()
taskstatus(::Type{Sleeping}, state) = Sleeping(parse(UInt64, state["until"]))
taskstatus(::Type{Waiting}, state) = Waiting(Int[state["on"]...])
taskstatus(::Type{Running}, state) = Running(state["cancelled"])
taskstatus(::Type{Completed}, state) = Completed(state["result"])
taskstatus(::Type{Failed}, state) = Failed(Symbol(state["reason"]))
taskstatus(::Type{Cancelled}, state) = Cancelled()

taskview(record::Task) = taskview(record, record.state)
taskview(record::Task, state) = nothing
function taskview(record::Task, state::AbstractDict)
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

millis() = floor(UInt64, time() * 1000)

Base.open(::Type{Scheduler}, path::AbstractString; now=millis) = open_scheduler(open(Store, path), now)
open_scheduler(rejected::Rejected, now) = rejected
function open_scheduler(store::Store, now)
    success = false
    try
        records = scan(store, Task)
        result = commit!(store) do tx
            for record in records
                recover!(tx, record, taskview(record))
            end
            nothing
        end
        finish_open!(store, result, now) do
            success = true
        end
    finally
        success || close(store)
    end
end
finish_open!(f, store::Store, rejected::Rejected, now) = rejected
function finish_open!(f, store::Store, ::Nothing, now)
    mutex = ReentrantLock()
    scheduler = Scheduler(store, mutex, 0, now, Threads.Condition(mutex))
    f()
    scheduler
end

function Base.close(scheduler::Scheduler)
    lock(scheduler.lock) do
        scheduler.active > 0 && return Rejected(:busy)
        result = close(scheduler.store)
        notify(scheduler.changed)
        result
    end
end

Base.get(scheduler::Scheduler, id::Integer) = taskview(get(scheduler.store, Task, id))

remaining(scheduler::Scheduler, result) = 0.0
remaining(scheduler::Scheduler, view::TaskView) = remaining(scheduler, view.status)
remaining(scheduler::Scheduler, status::TaskStatus) = 0.0
remaining(scheduler::Scheduler, status::Sleeping) = Float64(clamp(Int128(status.until) - Int128(scheduler.now()), 0, typemax(Int32))) / 1000

"""Wait until a sleeping task is due or changes state, without invoking its handler."""
function Base.wait(scheduler::Scheduler, id::Integer)
    lock(scheduler.lock) do
        while true
            view = get(scheduler, id)
            delay = remaining(scheduler, view)
            delay > 0 || return view
            timer = Timer(delay) do _
                lock(scheduler.lock) do
                    notify(scheduler.changed)
                end
            end
            try
                wait(scheduler.changed)
            finally
                close(timer)
            end
        end
    end
end

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

taskkey(::Nothing) = nothing
taskkey(request::AbstractString) = String(request)

function enqueue!(scheduler::Scheduler, conversation::Integer, handler::Handler, phase::Phase, input; request::Union{Nothing, AbstractString}=nothing, maxattempts::Integer=3, owner::Union{Nothing, Integer}=nothing)
    maxattempts > 0 || return Rejected(:invalid_attempt_limit)
    initial = checkpoint(encode(phase))
    spec = JSON3.read(codeunits(JSON3.write(Dict("kind" => name(handler), "input" => input, "initial" => initial, "maxattempts" => maxattempts))), Dict{String, Any})
    key = taskkey(request)
    lock(scheduler.lock) do
        commit!(scheduler.store) do tx
            enqueue!(tx, scheduler, conversation, handler, spec, key, owner, check_owner(tx, conversation, owner))
        end
    end
end

enqueue!(tx, scheduler, conversation, handler, spec, key, owner, rejected::Rejected) = rejected
function enqueue!(tx, scheduler, conversation, handler, spec, key, owner, ::Nothing)
    if key !== nothing
        for record in scan(scheduler.store, Task; conversation)
            view = taskview(record)
            view === nothing && continue
            view.request == key || continue
            return same(record.state["spec"], spec) && get(record.state, "owner", nothing) == owner ? record.id : Rejected(:request_conflict)
        end
    end
    id = mint!(tx)
    state = Dict("scheduler" => "JuliaForever.Scheduler/1", "spec" => spec, "request" => key, "checkpoint" => spec["initial"], "phase" => 1, "attempts" => 0, "restarts" => 0, "message" => nothing, "status" => "pending", "cancelled" => false, "result" => nothing, "reason" => nothing)
    setowner!(state, owner)
    put!(tx, Task(id, conversation, state))
end

setowner!(state, ::Nothing) = nothing
setowner!(state, owner::Integer) = (state["owner"] = owner)

check_owner(tx, conversation, ::Nothing) = nothing
check_owner(tx, conversation, owner::Integer) = check_owner(conversation, taskview(get(tx, Task, owner)))
check_owner(conversation, ::Nothing) = Rejected(:owner_missing)
check_owner(conversation, rejected::Rejected) = rejected
check_owner(conversation, view::TaskView) = check_owner(conversation, view, view.status)
check_owner(conversation, view::TaskView, ::Union{Pending, Sleeping, Waiting, Active}) = view.conversation == conversation ? nothing : Rejected(:owner_conversation)
check_owner(conversation, view::TaskView, ::TaskStatus) = Rejected(:owner_finished)

function reserve!(scheduler::Scheduler, id::Integer, handler::Handler)
    commit!(scheduler.store) do tx
        reserve!(tx, id, handler, get(tx, Task, id), scheduler.now)
    end
end

reserve!(tx::Transaction, id::Integer, handler::Handler, ::Nothing, now) = Rejected(:task_missing)
reserve!(tx::Transaction, id::Integer, handler::Handler, rejected::Rejected, now) = rejected
reserve!(tx::Transaction, id::Integer, handler::Handler, record::Task, now) = reserve!(tx, id, handler, record, taskview(record), now)
reserve!(tx::Transaction, id::Integer, handler::Handler, record::Task, ::Nothing, now) = Rejected(:not_scheduled)

function reserve!(tx::Transaction, id::Integer, handler::Handler, record::Task, view::TaskView, now)
    view.kind == name(handler) || return Rejected(:handler_mismatch)
    reserve!(tx, id, record, view.status, now)
end

reserve!(tx::Transaction, id::Integer, record::Task, ::TaskStatus, now) = Rejected(:not_pending)

joinstatus(tx::Transaction, ids) = foldl((status, id) -> joinstatus(status, tx, id), ids; init=Pending())
joinstatus(rejected::Rejected, tx::Transaction, id) = rejected
joinstatus(status::Pending, tx::Transaction, id) = joinstatus(status, taskview(get(tx, Task, id)))
joinstatus(status::Pending, view::TaskView) = joinstatus(status, view.status)
joinstatus(status::Pending, ::Union{Completed, Failed, Cancelled}) = status
joinstatus(::Pending, ::Union{TaskStatus, Nothing, Rejected}) = Rejected(:waiting)

reserve!(tx::Transaction, id::Integer, record::Task, rejected::Rejected, now) = rejected
reserve!(tx::Transaction, id::Integer, record::Task, status::Waiting, now) = reserve!(tx, id, record, joinstatus(tx, status.on), now)

function reserve!(tx::Transaction, id::Integer, record::Task, status::Sleeping, now)
    now() < status.until && return Rejected(:sleeping)
    reserve!(tx, id, record, Pending(), now)
end

function reserve!(tx::Transaction, id::Integer, record::Task, ::Pending, now)
    record.state["status"] = "running"
    record.state["attempts"] += 1
    delete!(record.state, "until")
    delete!(record.state, "on")
    taskview(tx, id, put!(tx, record))
end

function checkpoint!(state, next)
    state["checkpoint"] = next
    state["phase"] += 1
    state["attempts"] = 0
    state["message"] = nothing
end

function advance!(state, result::Next)
    next = JSON3.read(codeunits(JSON3.write(checkpoint(encode(result.phase)))), Dict{String, Any})
    same(state["checkpoint"], next) && return advance!(state, Retry("no checkpoint progress"))
    checkpoint!(state, next)
    state["status"] = "pending"
end

function advance!(state, result::Sleep)
    next = JSON3.read(codeunits(JSON3.write(checkpoint(encode(result.phase)))), Dict{String, Any})
    checkpoint!(state, next)
    state["until"] = string(result.until) # JSON3 can round large JSON numbers while decoding.
    state["status"] = "sleeping"
end

function advance!(state, result::Join)
    next = JSON3.read(codeunits(JSON3.write(checkpoint(encode(result.phase)))), Dict{String, Any})
    checkpoint!(state, next)
    state["on"] = result.on
    state["status"] = "waiting"
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
            notify(scheduler.changed)
        end
    end
end

step!(tx::Transaction, id::Integer, outcome, result) = result

function step!(tx::Transaction, id::Integer, outcome, record::Task)
    status = Running(record.state["cancelled"])
    step!(tx, id, outcome, record, status, validate_join(tx, id, outcome, status))
end
step!(tx, id, outcome, record, status, rejected::Rejected) = rejected
function step!(tx, id, outcome, record, status, ::Nothing)
    advance!(record.state, outcome, status)
    taskview(tx, id, put!(tx, record))
end

validate_join(tx, id, outcome, status) = nothing
validate_join(tx, id, outcome::Join, ::Active) = foldl((result, child) -> validate_child(tx, id, child, result), outcome.on; init=nothing)
validate_child(tx, id, child, rejected::Rejected) = rejected
validate_child(tx, id, child, ::Nothing) = check_child(tx, id, child, taskview(get(tx, Task, child)))
check_child(tx, id, child, ::Nothing) = Rejected(:task_missing)
check_child(tx, id, child, rejected::Rejected) = rejected
function check_child(tx, id, child, ::TaskView)
    reaches(tx, child, id, Set{Int}()) && return Rejected(:wait_cycle)
    nothing
end
function reaches(tx, current::Integer, target, seen)
    current == target && return true
    current in seen && return false
    push!(seen, current)
    reaches(tx, taskview(get(tx, Task, current)), target, seen)
end
reaches(tx, view, target, seen) = false
reaches(tx, view::TaskView, target, seen) = reaches(tx, view.status, target, seen)
reaches(tx, status::Waiting, target, seen) = any(id -> reaches(tx, id, target, seen), status.on)

function cancel!(scheduler::Scheduler, id::Integer)
    lock(scheduler.lock) do
        result = commit!(scheduler.store) do tx
            result = cancel!(tx, id, get(tx, Task, id))
            cancel_owned!(tx, scan(scheduler.store, Task), id, result)
            result
        end
        notify(scheduler.changed)
        result
    end
end

cancel!(tx::Transaction, id::Integer, ::Nothing) = Rejected(:task_missing)
cancel!(tx::Transaction, id::Integer, rejected::Rejected) = rejected
cancel!(tx::Transaction, id::Integer, record::Task) = cancel!(tx, id, record, taskview(record))
cancel!(tx::Transaction, id::Integer, record::Task, ::Nothing) = Rejected(:not_scheduled)
cancel!(tx::Transaction, id::Integer, record::Task, view::TaskView) = cancel!(tx, id, record, view, view.status)
cancel!(tx::Transaction, id::Integer, record::Task, view::TaskView, ::Union{Cancelled, Cancelling}) = view
cancel!(tx::Transaction, id::Integer, record::Task, view::TaskView, ::Union{Completed, Failed}) = Rejected(:finished)

function cancel!(tx::Transaction, id::Integer, record::Task, view::TaskView, ::Union{Pending, Sleeping, Waiting})
    record.state["status"] = "cancelled"
    delete!(record.state, "until")
    delete!(record.state, "on")
    taskview(tx, id, put!(tx, record))
end

function cancel!(tx::Transaction, id::Integer, record::Task, view::TaskView, ::Active)
    record.state["cancelled"] = true
    taskview(tx, id, put!(tx, record))
end

# Ownership is persisted on task records; old records without an owner are roots.
cancel_owned!(tx, records, id, result) = nothing
function cancel_owned!(tx, records, id, view::TaskView)
    for record in records
        owner(record.state) == id || continue
        child = cancel!(tx, record.id, get(tx, Task, record.id))
        cancel_owned!(tx, records, record.id, child)
    end
    nothing
end

owner(state) = nothing
owner(state::AbstractDict) = get(state, "owner", nothing)
