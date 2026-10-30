module Kernel

import ..JuliaForever: JSON3

abstract type Effect end
abstract type Observation end
abstract type Event end

struct Call{T} <: Effect
    name::String
    input::T
end

struct Return{T} <: Observation
    value::T
end

struct Fail{T} <: Observation
    value::T
end

same(a, b) = same(a, b, IdDict{Any, IdDict{Any, Nothing}}())

function seen!(seen, a, b)
    pairs = get!(seen, a, IdDict{Any, Nothing}())
    haskey(pairs, b) && return true
    pairs[b] = nothing
    false
end

same(a, b, seen) = false
same(a::T, b::T, seen) where {T <: Union{AbstractString, Symbol, Type, Function, Ptr, Module}} = isequal(a, b)

function same(a::T, b::T, seen) where T
    isequal(a, b) || return false
    isbitstype(T) && return true
    isstructtype(T) || return true
    ismutabletype(T) && seen!(seen, a, b) && return true
    for field in fieldnames(T)
        same(getfield(a, field), getfield(b, field), seen) || return false
    end
    true
end

function same(a::T, b::T, seen) where {T <: AbstractArray}
    axes(a) == axes(b) || return false
    seen!(seen, a, b) && return true
    for (x, y) in zip(a, b)
        same(x, y, seen) || return false
    end
    true
end

function same(a::T, b::T, seen) where {T <: AbstractDict}
    length(a) == length(b) || return false
    seen!(seen, a, b) && return true
    for (key, value) in a
        sameentry(key, value, b, seen) || return false
    end
    true
end

function sameentry(key, value, entries, seen)
    for (other, result) in entries
        same(key, other) || continue
        return same(value, result, seen)
    end
    false
end

function same(a::T, b::T, seen) where {T <: Tuple}
    length(a) == length(b) || return false
    for (x, y) in zip(a, b)
        same(x, y, seen) || return false
    end
    true
end

same(a::T, b::T, seen) where {T <: NamedTuple} = same(Tuple(a), Tuple(b), seen)

Base.isequal(a::Return, b::Return) = same(a.value, b.value)
Base.isequal(a::Fail, b::Fail) = same(a.value, b.value)
Base.hash(value::Return, h::UInt) = hash(value.value, hash(Return, h))
Base.hash(value::Fail, h::UInt) = hash(value.value, hash(Fail, h))

struct Pending{E <: Effect}
    id::String
    effect::E
end

struct Observed{O <: Observation}
    id::String
    observation::O
end

abstract type Status end
struct Open <: Status end
struct Closed <: Status end
const statuses = Dict(false => Open(), true => Closed())
status(value::Bool) = statuses[value]
closed(::Open) = false
closed(::Closed) = true

JSON3.StructTypes.StructType(::Type{<:Status}) = JSON3.StructTypes.CustomStruct()
JSON3.StructTypes.lowertype(::Type{<:Status}) = Bool
JSON3.StructTypes.lower(status::Status) = closed(status)
JSON3.StructTypes.construct(::Type{Status}, value::Bool) = status(value)

struct State
    id::String
    revision::Int
    pending::Vector{Pending}
    observations::Vector{Observed}
    status::Status

    function State(id, revision, pending, observations, status::Status)
        new(id, revision, pending, observations, status)
    end
end

State(id, revision, pending, observations, value) = State(id, revision, pending, observations, status(convert(Bool, value)))
State(id::AbstractString) = State(String(id), 0, Pending[], Observed[], false)

function Base.getproperty(state::State, name::Symbol)
    name === :closed && return closed(getfield(state, :status))
    value = getfield(state, name)
    name === :pending || name === :observations ? deepcopy(value) : value
end

Base.propertynames(::State, private::Bool=false) = (:id, :revision, :pending, :observations, :closed, :status)
JSON3.StructTypes.names(::Type{State}) = ((:status, :closed),)

struct Plan{E <: Effect} <: Event
    revision::Int
    id::String
    effect::E
end

struct Observe{O <: Observation} <: Event
    revision::Int
    id::String
    observation::O
end

struct Finish <: Event
    revision::Int
end

struct Applied{S, E <: Tuple}
    state::S
    effects::E
end

struct Duplicate{S}
    state::S
end

struct Rejected{S}
    state::S
    reason::Symbol
end

function step(state::State, event::Plan)
    event.revision == state.revision || return Rejected(state, :revision)
    step(state, event, getfield(state, :status))
end
step(state::State, event::Plan, ::Closed) = Rejected(state, :closed)
function step(state::State, event::Plan, ::Open)
    pending = getfield(state, :pending)
    observations = getfield(state, :observations)
    any(item -> item.id == event.id, pending) && return Rejected(state, :effect_in_use)
    any(item -> item.id == event.id, observations) && return Rejected(state, :effect_in_use)
    item = Pending(event.id, deepcopy(event.effect))
    next = copy(pending)
    push!(next, item)
    updated = State(state.id, state.revision + 1, next, copy(observations), false)
    Applied(updated, (deepcopy(item),))
end

function step(state::State, event::Observe)
    observations = getfield(state, :observations)
    previous = findfirst(item -> item.id == event.id, observations)
    observed(state, event, previous)
end
observed(state, event, index::Int) = isequal(getfield(state, :observations)[index].observation, event.observation) ? Duplicate(state) : Rejected(state, :observation_conflict)
function observed(state, event, ::Nothing)
    event.revision == state.revision || return Rejected(state, :revision)
    step(state, event, getfield(state, :status))
end
step(state::State, event::Observe, ::Closed) = Rejected(state, :closed)
function step(state::State, event::Observe, ::Open)
    pending = getfield(state, :pending)
    index = findfirst(item -> item.id == event.id, pending)
    observe(state, event, index)
end
observe(state, event, ::Nothing) = Rejected(state, :effect_missing)
function observe(state, event, index::Int)
    pending = getfield(state, :pending)
    observations = getfield(state, :observations)
    next = copy(pending)
    deleteat!(next, index)
    results = copy(observations)
    push!(results, Observed(event.id, deepcopy(event.observation)))
    updated = State(state.id, state.revision + 1, next, results, false)
    Applied(updated, ())
end

function step(state::State, event::Finish)
    event.revision == state.revision || return Rejected(state, :revision)
    step(state, event, getfield(state, :status))
end
step(state::State, event::Finish, ::Closed) = Rejected(state, :closed)
function step(state::State, event::Finish, ::Open)
    isempty(getfield(state, :pending)) || return Rejected(state, :pending)
    updated = State(state.id, state.revision + 1, copy(getfield(state, :pending)), copy(getfield(state, :observations)), true)
    Applied(updated, ())
end

struct Replay{S}
    initial::S
    events::Vector{Event}

    function Replay(initial::S, events::Union{AbstractVector, Tuple}) where S
        new{S}(deepcopy(initial), Event[deepcopy(event) for event in events])
    end
end

function Base.getproperty(replay::Replay, name::Symbol)
    value = getfield(replay, name)
    name === :events ? deepcopy(value) : value
end

Base.IteratorSize(::Type{<:Replay}) = Base.SizeUnknown()
Base.IteratorEltype(::Type{<:Replay}) = Base.EltypeUnknown()
Base.iterate(replay::Replay) = iterate(replay, (getfield(replay, :initial), 1))

cursor(result::Rejected, events, index) = (result.state, length(events) + 1)
cursor(result, events, index) = (result.state, index + 1)

function Base.iterate(replay::Replay, position::Tuple{S, Int}) where S
    state, index = position
    events = getfield(replay, :events)
    index > length(events) && return nothing
    result = step(state, events[index])
    result, cursor(result, events, index)
end

end
