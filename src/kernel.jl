module Kernel

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

function same(a, b, seen)
    typeof(a) === typeof(b) && isequal(a, b) || return false
    type = typeof(a)
    (isbitstype(type) || a isa Union{AbstractString, Symbol, Type, Function, Ptr, Module}) && return true
    isstructtype(type) || return true
    ismutabletype(type) && seen!(seen, a, b) && return true
    for field in fieldnames(type)
        same(getfield(a, field), getfield(b, field), seen) || return false
    end
    true
end

function same(a::AbstractArray, b::AbstractArray, seen)
    typeof(a) === typeof(b) && axes(a) == axes(b) || return false
    seen!(seen, a, b) && return true
    for (x, y) in zip(a, b)
        same(x, y, seen) || return false
    end
    true
end

function same(a::AbstractDict, b::AbstractDict, seen)
    typeof(a) === typeof(b) && length(a) == length(b) || return false
    seen!(seen, a, b) && return true
    for (key, value) in a
        found = false
        for (other, result) in b
            if same(key, other)
                same(value, result, seen) || return false
                found = true
                break
            end
        end
        found || return false
    end
    true
end

function same(a::Tuple, b::Tuple, seen)
    typeof(a) === typeof(b) && length(a) == length(b) || return false
    for (x, y) in zip(a, b)
        same(x, y, seen) || return false
    end
    true
end

function same(a::NamedTuple, b::NamedTuple, seen)
    typeof(a) === typeof(b) && same(Tuple(a), Tuple(b), seen)
end

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

struct State
    id::String
    revision::Int
    pending::Vector{Pending}
    observations::Vector{Observed}
    closed::Bool
end

State(id::AbstractString) = State(String(id), 0, Pending[], Observed[], false)

function Base.getproperty(state::State, name::Symbol)
    value = getfield(state, name)
    name === :pending || name === :observations ? deepcopy(value) : value
end

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
    state.closed && return Rejected(state, :closed)
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
    if previous !== nothing
        isequal(observations[previous].observation, event.observation) && return Duplicate(state)
        return Rejected(state, :observation_conflict)
    end
    event.revision == state.revision || return Rejected(state, :revision)
    state.closed && return Rejected(state, :closed)
    pending = getfield(state, :pending)
    index = findfirst(item -> item.id == event.id, pending)
    index === nothing && return Rejected(state, :effect_missing)
    next = copy(pending)
    deleteat!(next, index)
    results = copy(observations)
    push!(results, Observed(event.id, deepcopy(event.observation)))
    updated = State(state.id, state.revision + 1, next, results, false)
    Applied(updated, ())
end

function step(state::State, event::Finish)
    event.revision == state.revision || return Rejected(state, :revision)
    state.closed && return Rejected(state, :closed)
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

function Base.iterate(replay::Replay, cursor::Tuple{S, Int}) where S
    state, index = cursor
    events = getfield(replay, :events)
    index > length(events) && return nothing
    result = step(state, events[index])
    next = result isa Rejected ? length(events) + 1 : index + 1
    result, (result.state, next)
end

end
