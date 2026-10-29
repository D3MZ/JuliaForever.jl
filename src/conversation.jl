module Conversation

import ..Kernel as K

abstract type Message end

struct User <: Message
    content::String
end

struct RawMessage <: Message
    value::Dict{String, Any}
end

struct ToolCall
    id::String
    name::Union{Nothing, String}
    arguments::Union{Nothing, String}
    metadata::Dict{String, Any}

    function ToolCall(id, name, arguments, metadata::AbstractDict)
        new(id, name, arguments, deepcopy(Dict{String, Any}(metadata)))
    end
end

ToolCall(id, name, arguments; metadata=Dict{String, Any}()) = ToolCall(id, name, arguments, metadata)

struct Assistant <: Message
    content::Union{Nothing, String}
    calls::Vector{ToolCall}
    finish::Union{Nothing, String}
    done::Bool
    metadata::Dict{String, Any}

    function Assistant(content, calls, finish, done, metadata::AbstractDict)
        new(content, deepcopy(calls), finish, done, deepcopy(Dict{String, Any}(metadata)))
    end
end

Assistant(content, calls, finish, done; metadata=Dict{String, Any}()) = Assistant(content, calls, finish, done, metadata)

struct ToolMessage <: Message
    id::String
    content::String
    iserror::Bool
end

struct ModelRequest <: K.Effect
    messages::Vector{Message}
end

struct ToolRequest <: K.Effect
    call::ToolCall
end

struct SkipRequest <: K.Effect
    call::ToolCall
end

struct ModelReply <: K.Observation
    message::Assistant
end

struct ToolReply <: K.Observation
    text::String
    iserror::Bool
end

struct ModelFailure <: K.Observation
    reason::String
end

struct Abandoned <: K.Observation
    reason::String
end

Base.isequal(a::ToolCall, b::ToolCall) = K.same((a.id, a.name, a.arguments, a.metadata), (b.id, b.name, b.arguments, b.metadata))
Base.isequal(a::Assistant, b::Assistant) = K.same((a.content, a.calls, a.finish, a.done, a.metadata), (b.content, b.calls, b.finish, b.done, b.metadata))
Base.isequal(a::ModelReply, b::ModelReply) = isequal(a.message, b.message)
Base.isequal(a::ToolReply, b::ToolReply) = isequal((a.text, a.iserror), (b.text, b.iserror))
Base.isequal(a::ModelFailure, b::ModelFailure) = isequal(a.reason, b.reason)
Base.isequal(a::Abandoned, b::Abandoned) = isequal(a.reason, b.reason)
Base.hash(value::ToolCall, h::UInt) = hash((value.id, value.name, value.arguments, value.metadata), hash(ToolCall, h))
Base.hash(value::Assistant, h::UInt) = hash((value.content, value.calls, value.finish, value.done, value.metadata), hash(Assistant, h))
Base.hash(value::ModelReply, h::UInt) = hash(value.message, hash(ModelReply, h))
Base.hash(value::ToolReply, h::UInt) = hash((value.text, value.iserror), hash(ToolReply, h))
Base.hash(value::ModelFailure, h::UInt) = hash(value.reason, hash(ModelFailure, h))
Base.hash(value::Abandoned, h::UInt) = hash(value.reason, hash(Abandoned, h))

@enum Phase Ready ReadyModel ReadyDecision WaitingModel WaitingTools Complete Incomplete Cancelled

struct State
    kernel::K.State
    revision::Int
    messages::Vector{Message}
    phase::Phase
    order::Vector{String}
    calls::Vector{ToolCall}
    steering::Vector{String}
    followups::Vector{String}
    automatic::Bool
    cancelled::Bool
    flushed::Int
end

State(id::AbstractString; automatic=true, messages=Message[]) = State(K.State(id), 0, deepcopy(Message[messages...]), Ready, String[], ToolCall[], String[], String[], automatic, false, 0)

function Base.getproperty(state::State, name::Symbol)
    value = getfield(state, name)
    name in (:messages, :order, :calls, :steering, :followups) ? deepcopy(value) : value
end

struct Input <: K.Event
    revision::Int
    text::String
end

struct Steer <: K.Event
    revision::Int
    text::String
end

struct Followup <: K.Event
    revision::Int
    text::String
end

struct Advance <: K.Event
    revision::Int
end

struct Cancel <: K.Event
    revision::Int
end

struct History <: K.Event
    revision::Int
    messages::Vector{Message}
end

struct Interrupt <: K.Event
    revision::Int
    reason::String
end

function update(state::State; kernel=getfield(state, :kernel), messages=getfield(state, :messages), phase=state.phase, order=getfield(state, :order), calls=getfield(state, :calls), steering=getfield(state, :steering), followups=getfield(state, :followups), cancelled=state.cancelled, flushed=state.flushed)
    State(kernel, state.revision + 1, messages, phase, order, calls, steering, followups, state.automatic, cancelled, flushed)
end

function plan(kernel::K.State, effect::K.Effect)
    id = string(kernel.id, ":", kernel.revision + 1)
    result = K.step(kernel, K.Plan(kernel.revision, id, effect))
    result.state, only(result.effects)
end

function model(kernel::K.State, messages::Vector{Message}, steering::Vector{String})
    if !isempty(steering)
        steering = copy(steering)
        push!(messages, User(popfirst!(steering)))
    end
    kernel, effect = plan(kernel, ModelRequest(messages))
    kernel, effect, steering
end

function K.step(state::State, event::Input)
    event.revision == state.revision || return K.Rejected(state, :revision)
    state.phase in (Ready, Complete, Incomplete, Cancelled) || return K.Rejected(state, :phase)
    messages = copy(getfield(state, :messages))
    push!(messages, User(event.text))
    state.automatic || return K.Applied(update(state; messages, phase=ReadyModel, cancelled=false), ())
    kernel, effect, steering = model(state.kernel, messages, getfield(state, :steering))
    updated = update(state; kernel, messages, steering, phase=WaitingModel, cancelled=false)
    K.Applied(updated, (effect,))
end

function K.step(state::State, event::Steer)
    event.revision == state.revision || return K.Rejected(state, :revision)
    steering = copy(getfield(state, :steering))
    push!(steering, event.text)
    K.Applied(update(state; steering), ())
end

function K.step(state::State, event::Followup)
    event.revision == state.revision || return K.Rejected(state, :revision)
    followups = copy(getfield(state, :followups))
    push!(followups, event.text)
    K.Applied(update(state; followups), ())
end

function K.step(state::State, event::Cancel)
    event.revision == state.revision || return K.Rejected(state, :revision)
    K.Applied(update(state; cancelled=true), ())
end

function K.step(state::State, event::History)
    event.revision == state.revision || return K.Rejected(state, :revision)
    K.Applied(update(state; messages=deepcopy(event.messages)), ())
end

function K.step(state::State, event::Interrupt)
    event.revision == state.revision || return K.Rejected(state, :revision)
    kernel = state.kernel
    for pending in kernel.pending
        result = K.step(kernel, K.Observe(kernel.revision, pending.id, Abandoned(event.reason)))
        kernel = result.state
    end
    K.Applied(update(state; kernel, phase=Incomplete, order=String[], calls=ToolCall[], flushed=0), ())
end

function K.step(state::State, event::Advance)
    event.revision == state.revision || return K.Rejected(state, :revision)
    state.phase in (ReadyModel, ReadyDecision) || return K.Rejected(state, :phase)
    state.cancelled && return K.Applied(update(state; phase=Cancelled), ())
    steering = getfield(state, :steering)
    followups = getfield(state, :followups)
    if state.phase == ReadyDecision && isempty(steering) && isempty(followups)
        return K.Applied(update(state; phase=Complete), ())
    end
    messages = copy(getfield(state, :messages))
    if state.phase == ReadyDecision && isempty(steering)
        followups = copy(followups)
        push!(messages, User(popfirst!(followups)))
    end
    kernel, effect, steering = model(state.kernel, messages, steering)
    updated = update(state; kernel, messages, steering, followups, phase=WaitingModel)
    K.Applied(updated, (effect,))
end

function observe(state::State, event::K.Observe, phase::Phase)
    result = K.step(state.kernel, K.Observe(state.kernel.revision, event.id, event.observation))
    result isa K.Duplicate && return K.Duplicate(state)
    result isa K.Rejected && return K.Rejected(state, result.reason)
    event.revision == state.revision || return K.Rejected(state, :revision)
    state.phase == phase || return K.Rejected(state, :phase)
    result
end

function K.step(state::State, event::K.Observe{ModelReply})
    result = observe(state, event, WaitingModel)
    result isa K.Applied || return result
    kernel = result.state
    answer = deepcopy(event.observation.message)
    answer.done || return K.Applied(update(state; kernel, phase=Incomplete), ())
    messages = copy(getfield(state, :messages))
    push!(messages, answer)
    steering = getfield(state, :steering)
    followups = getfield(state, :followups)
    if isempty(answer.calls)
        state.automatic || return K.Applied(update(state; kernel, messages, phase=ReadyDecision), ())
        if isempty(steering) && isempty(followups)
            return K.Applied(update(state; kernel, messages, phase=Complete), ())
        end
        if isempty(steering)
            followups = copy(followups)
            push!(messages, User(popfirst!(followups)))
        end
        kernel, effect, steering = model(kernel, messages, steering)
        return K.Applied(update(state; kernel, messages, steering, followups, phase=WaitingModel), (effect,))
    end
    if answer.finish == "length" && state.automatic
        for call in answer.calls
            text = "Error: Tool call \"$(call.name)\" was not executed: the response hit the output token limit, so its arguments may be truncated. Re-issue the tool call with complete arguments."
            push!(messages, ToolMessage(call.id, text, true))
        end
        kernel, effect, steering = model(kernel, messages, steering)
        return K.Applied(update(state; kernel, messages, steering, phase=WaitingModel), (effect,))
    end
    effects = K.Pending[]
    for call in answer.calls
        request = answer.finish == "length" ? SkipRequest(call) : ToolRequest(call)
        kernel, effect = plan(kernel, request)
        push!(effects, effect)
    end
    order = [effect.id for effect in effects]
    calls = deepcopy(answer.calls)
    updated = update(state; kernel, messages, order, calls, phase=WaitingTools)
    K.Applied(updated, Tuple(effects))
end

function K.step(state::State, event::K.Observe{ToolReply})
    result = observe(state, event, WaitingTools)
    result isa K.Applied || return result
    kernel = result.state
    messages = copy(getfield(state, :messages))
    observations = kernel.observations
    order = getfield(state, :order)
    calls = getfield(state, :calls)
    flushed = state.flushed
    while flushed < length(order)
        id = order[flushed + 1]
        index = findfirst(item -> item.id == id, observations)
        index === nothing && break
        observation = observations[index].observation
        call = calls[flushed + 1]
        content = observation.iserror ? "Error: " * observation.text : observation.text
        push!(messages, ToolMessage(call.id, content, observation.iserror))
        flushed += 1
    end
    if !isempty(kernel.pending)
        return K.Applied(update(state; kernel, messages, flushed), ())
    end
    state.automatic || return K.Applied(update(state; kernel, messages, order=String[], calls=ToolCall[], flushed=0, phase=ReadyModel), ())
    kernel, effect, steering = model(kernel, messages, getfield(state, :steering))
    updated = update(state; kernel, messages, steering, order=String[], calls=ToolCall[], flushed=0, phase=WaitingModel)
    K.Applied(updated, (effect,))
end

function K.step(state::State, event::K.Observe{ModelFailure})
    result = observe(state, event, WaitingModel)
    result isa K.Applied || return result
    K.Applied(update(state; kernel=result.state, phase=state.cancelled ? Cancelled : Incomplete), ())
end

K.step(state::State, event::K.Observe) = K.Rejected(state, :observation_type)

end
