module Conversation

import ..Kernel as K

abstract type Message end

struct User <: Message
    content::String
end

struct ToolCall
    id::String
    name::Union{Nothing, String}
    arguments::Union{Nothing, String}
end

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

struct ModelReply <: K.Observation
    message::Assistant
end

struct ToolReply <: K.Observation
    text::String
    iserror::Bool
end

Base.isequal(a::ToolCall, b::ToolCall) = isequal((a.id, a.name, a.arguments), (b.id, b.name, b.arguments))
Base.isequal(a::Assistant, b::Assistant) = K.same((a.content, a.calls, a.finish, a.done, a.metadata), (b.content, b.calls, b.finish, b.done, b.metadata))
Base.isequal(a::ModelReply, b::ModelReply) = isequal(a.message, b.message)
Base.isequal(a::ToolReply, b::ToolReply) = isequal((a.text, a.iserror), (b.text, b.iserror))
Base.hash(value::ToolCall, h::UInt) = hash((value.id, value.name, value.arguments), hash(ToolCall, h))
Base.hash(value::Assistant, h::UInt) = hash((value.content, value.calls, value.finish, value.done, value.metadata), hash(Assistant, h))
Base.hash(value::ModelReply, h::UInt) = hash(value.message, hash(ModelReply, h))
Base.hash(value::ToolReply, h::UInt) = hash((value.text, value.iserror), hash(ToolReply, h))

@enum Phase Ready WaitingModel WaitingTools Complete Incomplete

struct State
    kernel::K.State
    revision::Int
    messages::Vector{Message}
    phase::Phase
    order::Vector{String}
    calls::Vector{ToolCall}
    steering::Vector{String}
    followups::Vector{String}
end

State(id::AbstractString) = State(K.State(id), 0, Message[], Ready, String[], ToolCall[], String[], String[])

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

function update(state::State; kernel=getfield(state, :kernel), messages=getfield(state, :messages), phase=state.phase, order=getfield(state, :order), calls=getfield(state, :calls), steering=getfield(state, :steering), followups=getfield(state, :followups))
    State(kernel, state.revision + 1, messages, phase, order, calls, steering, followups)
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
    state.phase in (Ready, Complete, Incomplete) || return K.Rejected(state, :phase)
    messages = copy(getfield(state, :messages))
    push!(messages, User(event.text))
    kernel, effect, steering = model(state.kernel, messages, getfield(state, :steering))
    updated = update(state; kernel, messages, steering, phase=WaitingModel)
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
    if answer.finish == "length"
        for call in answer.calls
            text = "Error: Tool call \"$(call.name)\" was not executed: the response hit the output token limit, so its arguments may be truncated. Re-issue the tool call with complete arguments."
            push!(messages, ToolMessage(call.id, text, true))
        end
        kernel, effect, steering = model(kernel, messages, steering)
        return K.Applied(update(state; kernel, messages, steering, phase=WaitingModel), (effect,))
    end
    effects = K.Pending[]
    for call in answer.calls
        kernel, effect = plan(kernel, ToolRequest(call))
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
    if !isempty(kernel.pending)
        return K.Applied(update(state; kernel), ())
    end
    messages = copy(getfield(state, :messages))
    observations = kernel.observations
    for (id, call) in zip(getfield(state, :order), getfield(state, :calls))
        observation = only(item.observation for item in observations if item.id == id)
        content = observation.iserror ? "Error: " * observation.text : observation.text
        push!(messages, ToolMessage(call.id, content, observation.iserror))
    end
    kernel, effect, steering = model(kernel, messages, getfield(state, :steering))
    updated = update(state; kernel, messages, steering, order=String[], calls=ToolCall[], phase=WaitingModel)
    K.Applied(updated, (effect,))
end

K.step(state::State, event::K.Observe) = K.Rejected(state, :observation_type)

end
