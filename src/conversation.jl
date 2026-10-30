module Conversation

import ..Kernel as K
import ..JuliaForever: Image, ToolResult, content, CompletionStatus, Finished, Unfinished, completionstatus, finished, JSON3

abstract type Message end

struct User <: Message
    content::String
end

struct Summary <: Message
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
    status::CompletionStatus
    metadata::Dict{String, Any}

    function Assistant(content, calls, finish, status::CompletionStatus, metadata::AbstractDict)
        new(content, deepcopy(calls), finish, status, deepcopy(Dict{String, Any}(metadata)))
    end
end

Assistant(content, calls, finish, done, metadata::AbstractDict) = Assistant(content, calls, finish, completionstatus(convert(Bool, done)), metadata)
Assistant(content, calls, finish, done; metadata=Dict{String, Any}()) = Assistant(content, calls, finish, done, metadata)
Base.getproperty(message::Assistant, name::Symbol) = name === :done ? finished(getfield(message, :status)) : getfield(message, name)
Base.propertynames(::Assistant, private::Bool=false) = (:content, :calls, :finish, :done, :metadata, :status)
JSON3.StructTypes.names(::Type{Assistant}) = ((:status, :done),)

struct ToolMessage <: Message
    id::String
    content::String
    iserror::Bool
    image::Union{Nothing, Image}
end

ToolMessage(id, content, iserror) = ToolMessage(id, content, iserror, nothing)

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
    result::ToolResult
end

ToolReply(text, iserror::Bool) = ToolReply(ToolResult(text, iserror))
ToolReply(text, iserror::Bool, image) = ToolReply(ToolResult(text, iserror, image))

function Base.getproperty(reply::ToolReply, name::Symbol)
    name in (:text, :iserror, :image) && return getproperty(getfield(reply, :result), name)
    getfield(reply, name)
end

Base.propertynames(::ToolReply, private::Bool=false) = (:text, :iserror, :image, :result)

ToolMessage(call::ToolCall, reply::ToolReply) = ToolMessage(call.id, content(reply.result), reply.iserror, reply.image)
ToolMessage(call::ToolCall, reply::ToolReply, reason::AbstractString) = ToolMessage(call, reply)
ToolMessage(call::ToolCall, observation, reason::AbstractString) = ToolMessage(call.id, "Error: Tool outcome unknown; abandoned: " * reason, true)

struct ModelFailure <: K.Observation
    reason::String
end

struct Abandoned <: K.Observation
    reason::String
end

Base.isequal(a::ToolCall, b::ToolCall) = K.same((a.id, a.name, a.arguments, a.metadata), (b.id, b.name, b.arguments, b.metadata))
Base.isequal(a::Assistant, b::Assistant) = K.same((a.content, a.calls, a.finish, a.done, a.metadata), (b.content, b.calls, b.finish, b.done, b.metadata))
Base.isequal(a::ModelReply, b::ModelReply) = isequal(a.message, b.message)
Base.isequal(a::ToolReply, b::ToolReply) = isequal((a.text, a.iserror, a.image), (b.text, b.iserror, b.image))
Base.isequal(a::ModelFailure, b::ModelFailure) = isequal(a.reason, b.reason)
Base.isequal(a::Abandoned, b::Abandoned) = isequal(a.reason, b.reason)
Base.hash(value::ToolCall, h::UInt) = hash((value.id, value.name, value.arguments, value.metadata), hash(ToolCall, h))
Base.hash(value::Assistant, h::UInt) = hash((value.content, value.calls, value.finish, value.done, value.metadata), hash(Assistant, h))
Base.hash(value::ModelReply, h::UInt) = hash(value.message, hash(ModelReply, h))
Base.hash(value::ToolReply, h::UInt) = hash((value.text, value.iserror, value.image), hash(ToolReply, h))
Base.hash(value::ModelFailure, h::UInt) = hash(value.reason, hash(ModelFailure, h))
Base.hash(value::Abandoned, h::UInt) = hash(value.reason, hash(Abandoned, h))

abstract type Phase end
struct ReadyPhase <: Phase end
struct ReadyModelPhase <: Phase end
struct ReadyDecisionPhase <: Phase end
struct WaitingModelPhase <: Phase end
struct WaitingToolsPhase <: Phase end
struct CompletePhase <: Phase end
struct IncompletePhase <: Phase end
struct CancelledPhase <: Phase end

const Ready = ReadyPhase()
const ReadyModel = ReadyModelPhase()
const ReadyDecision = ReadyDecisionPhase()
const WaitingModel = WaitingModelPhase()
const WaitingTools = WaitingToolsPhase()
const Complete = CompletePhase()
const Incomplete = IncompletePhase()
const Cancelled = CancelledPhase()

Base.instances(::Type{Phase}) = (Ready, ReadyModel, ReadyDecision, WaitingModel, WaitingTools, Complete, Incomplete, Cancelled)
Phase(value::Integer) = instances(Phase)[Int(value) + 1]
phasecode(::ReadyPhase) = 0
phasecode(::ReadyModelPhase) = 1
phasecode(::ReadyDecisionPhase) = 2
phasecode(::WaitingModelPhase) = 3
phasecode(::WaitingToolsPhase) = 4
phasecode(::CompletePhase) = 5
phasecode(::IncompletePhase) = 6
phasecode(::CancelledPhase) = 7
Base.convert(::Type{T}, phase::Phase) where {T <: Integer} = convert(T, phasecode(phase))
(::Type{T})(phase::Phase) where {T <: Integer} = convert(T, phase)
Base.broadcastable(phase::Phase) = Ref(phase)
Base.isless(a::Phase, b::Phase) = isless(phasecode(a), phasecode(b))
Base.:<(a::Phase, b::Phase) = phasecode(a) < phasecode(b)
Base.:<=(a::Phase, b::Phase) = phasecode(a) <= phasecode(b)

Base.show(io::IO, ::ReadyPhase) = print(io, "Ready")
Base.show(io::IO, ::ReadyModelPhase) = print(io, "ReadyModel")
Base.show(io::IO, ::ReadyDecisionPhase) = print(io, "ReadyDecision")
Base.show(io::IO, ::WaitingModelPhase) = print(io, "WaitingModel")
Base.show(io::IO, ::WaitingToolsPhase) = print(io, "WaitingTools")
Base.show(io::IO, ::CompletePhase) = print(io, "Complete")
Base.show(io::IO, ::IncompletePhase) = print(io, "Incomplete")
Base.show(io::IO, ::CancelledPhase) = print(io, "Cancelled")

abstract type Driving end
struct Automatic <: Driving end
struct Manual <: Driving end
abstract type Cancellation end
struct Active <: Cancellation end
struct Requested <: Cancellation end

const drivingmodes = Dict(true => Automatic(), false => Manual())
const cancellationstates = Dict(true => Requested(), false => Active())
driving(value::Bool) = drivingmodes[value]
driving(value::Driving) = value
driving(value) = driving(convert(Bool, value))
cancellation(value::Bool) = cancellationstates[value]
cancellation(value::Cancellation) = value
cancellation(value) = cancellation(convert(Bool, value))
automatic(::Automatic) = true
automatic(::Manual) = false
cancelled(::Requested) = true
cancelled(::Active) = false

JSON3.StructTypes.StructType(::Type{<:Driving}) = JSON3.StructTypes.CustomStruct()
JSON3.StructTypes.lowertype(::Type{<:Driving}) = Bool
JSON3.StructTypes.lower(mode::Driving) = automatic(mode)
JSON3.StructTypes.construct(::Type{Driving}, value::Bool) = driving(value)
JSON3.StructTypes.StructType(::Type{<:Cancellation}) = JSON3.StructTypes.CustomStruct()
JSON3.StructTypes.lowertype(::Type{<:Cancellation}) = Bool
JSON3.StructTypes.lower(status::Cancellation) = cancelled(status)
JSON3.StructTypes.construct(::Type{Cancellation}, value::Bool) = cancellation(value)

struct State
    kernel::K.State
    revision::Int
    messages::Vector{Message}
    phase::Phase
    order::Vector{String}
    calls::Vector{ToolCall}
    steering::Vector{String}
    followups::Vector{String}
    mode::Driving
    cancellation::Cancellation
    flushed::Int

    function State(kernel, revision, messages, phase, order, calls, steering, followups, mode::Driving, cancellation::Cancellation, flushed)
        new(kernel, revision, messages, phase, order, calls, steering, followups, mode, cancellation, flushed)
    end
end

State(kernel, revision, messages, phase, order, calls, steering, followups, automatic, cancelled, flushed) = State(kernel, revision, messages, phase, order, calls, steering, followups, driving(automatic), cancellation(cancelled), flushed)
State(id::AbstractString; automatic=true, messages=Message[]) = State(K.State(id), 0, deepcopy(Message[messages...]), Ready, String[], ToolCall[], String[], String[], automatic, false, 0)

function Base.getproperty(state::State, name::Symbol)
    name === :automatic && return automatic(getfield(state, :mode))
    name === :cancelled && return cancelled(getfield(state, :cancellation))
    value = getfield(state, name)
    name in (:messages, :order, :calls, :steering, :followups) ? deepcopy(value) : value
end

Base.propertynames(::State, private::Bool=false) = (:kernel, :revision, :messages, :phase, :order, :calls, :steering, :followups, :automatic, :cancelled, :flushed, :mode, :cancellation)
JSON3.StructTypes.names(::Type{State}) = ((:mode, :automatic), (:cancellation, :cancelled))

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

struct Dequeue <: K.Event
    revision::Int
end

struct SessionName <: K.Event
    revision::Int
    name::String
end

sessionname(text::AbstractString) = String(strip(replace(text, r"[\r\n]+" => " ")))

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

struct Abandon <: K.Event
    revision::Int
    reason::String
end

function update(state::State; kernel=getfield(state, :kernel), messages=getfield(state, :messages), phase=state.phase, order=getfield(state, :order), calls=getfield(state, :calls), steering=getfield(state, :steering), followups=getfield(state, :followups), cancelled=getfield(state, :cancellation), flushed=state.flushed)
    State(kernel, state.revision + 1, messages, phase, order, calls, steering, followups, getfield(state, :mode), cancelled, flushed)
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
    K.step(state, event, state.phase)
end

K.step(state::State, event::Input, ::Phase) = K.Rejected(state, :phase)

function K.step(state::State, event::Input, ::Union{ReadyPhase, CompletePhase, IncompletePhase, CancelledPhase})
    messages = copy(getfield(state, :messages))
    push!(messages, User(event.text))
    input(state, messages, getfield(state, :mode))
end

input(state, messages, ::Manual) = K.Applied(update(state; messages, phase=ReadyModel, cancelled=false), ())
function input(state, messages, ::Automatic)
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

function K.step(state::State, event::Dequeue)
    event.revision == state.revision || return K.Rejected(state, :revision)
    K.Applied(update(state; steering=String[], followups=String[]), ())
end

function K.step(state::State, event::SessionName)
    event.revision == state.revision || return K.Rejected(state, :revision)
    K.Applied(update(state), ())
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

function K.step(state::State, event::Abandon)
    event.revision == state.revision || return K.Rejected(state, :revision)
    kernel = state.kernel
    for pending in kernel.pending
        result = K.step(kernel, K.Observe(kernel.revision, pending.id, Abandoned(event.reason)))
        kernel = result.state
    end
    messages = copy(getfield(state, :messages))
    abandon!(messages, state, kernel, event, state.phase)
    K.Applied(update(state; kernel, messages, phase=Incomplete, order=String[], calls=ToolCall[], flushed=0), ())
end

abandon!(messages, state, kernel, event, ::Phase) = nothing

function abandon!(messages, state, kernel, event, ::WaitingToolsPhase)
    order = getfield(state, :order)
    calls = getfield(state, :calls)
    observations = kernel.observations
    for index in state.flushed+1:length(order)
        observation = only(item.observation for item in observations if item.id == order[index])
        push!(messages, ToolMessage(calls[index], observation, event.reason))
    end
    nothing
end

function K.step(state::State, event::Advance)
    event.revision == state.revision || return K.Rejected(state, :revision)
    advance(state, state.phase)
end

advance(state::State, ::Phase) = K.Rejected(state, :phase)

advance(state::State, phase::Union{ReadyModelPhase, ReadyDecisionPhase}) = advance(state, phase, getfield(state, :cancellation))
advance(state::State, phase, ::Requested) = K.Applied(update(state; phase=Cancelled), ())
function advance(state::State, phase, ::Active)
    steering = getfield(state, :steering)
    followups = getfield(state, :followups)
    advance(state, phase, steering, followups)
end

function advance(state::State, ::ReadyDecisionPhase, steering, followups)
    isempty(steering) && isempty(followups) && return K.Applied(update(state; phase=Complete), ())
    messages = copy(getfield(state, :messages))
    if isempty(steering)
        followups = copy(followups)
        push!(messages, User(popfirst!(followups)))
    end
    advance(state, messages, steering, followups)
end

advance(state::State, ::ReadyModelPhase, steering, followups) = advance(state, copy(getfield(state, :messages)), steering, followups)

function advance(state::State, messages::Vector{Message}, steering, followups)
    kernel, effect, steering = model(state.kernel, messages, steering)
    updated = update(state; kernel, messages, steering, followups, phase=WaitingModel)
    K.Applied(updated, (effect,))
end

function observe(state::State, event::K.Observe, phase::Phase)
    result = K.step(state.kernel, K.Observe(state.kernel.revision, event.id, event.observation))
    observe(state, event, phase, result)
end

observe(state::State, event::K.Observe, phase::Phase, ::K.Duplicate) = K.Duplicate(state)
observe(state::State, event::K.Observe, phase::Phase, result::K.Rejected) = K.Rejected(state, result.reason)

function observe(state::State, event::K.Observe, phase::Phase, result::K.Applied)
    event.revision == state.revision || return K.Rejected(state, :revision)
    observe(state, state.phase, phase, result)
end

observe(state::State, actual::Phase, expected::Phase, result::K.Applied) = K.Rejected(state, :phase)
observe(state::State, actual::T, expected::T, result::K.Applied) where {T <: Phase} = result
observe(state::State, event::K.Observe, result::Union{K.Rejected, K.Duplicate}) = result
K.step(state::State, event::K.Observe{ModelReply}) = observe(state, event, observe(state, event, WaitingModel))

function observe(state::State, event::K.Observe{ModelReply}, result::K.Applied)
    kernel = result.state
    answer = deepcopy(event.observation.message)
    observe(state, kernel, answer, getfield(answer, :status))
end

observe(state::State, kernel::K.State, answer::Assistant, ::Unfinished) = K.Applied(update(state; kernel, phase=Incomplete), ())
function observe(state::State, kernel::K.State, answer::Assistant, ::Finished)
    messages = copy(getfield(state, :messages))
    push!(messages, answer)
    steering = getfield(state, :steering)
    followups = getfield(state, :followups)
    if isempty(answer.calls)
        return observe_text(state, kernel, messages, steering, followups, getfield(state, :mode))
    end
    observe_calls(state, kernel, messages, steering, answer, get(requesttypes, answer.finish, ToolRequest))
end

observe_text(state, kernel, messages, steering, followups, ::Manual) = K.Applied(update(state; kernel, messages, phase=ReadyDecision), ())
function observe_text(state, kernel, messages, steering, followups, ::Automatic)
    if isempty(steering) && isempty(followups)
        return K.Applied(update(state; kernel, messages, phase=Complete), ())
    end
    if isempty(steering)
        followups = copy(followups)
        push!(messages, User(popfirst!(followups)))
    end
    kernel, effect, steering = model(kernel, messages, steering)
    K.Applied(update(state; kernel, messages, steering, followups, phase=WaitingModel), (effect,))
end

const requesttypes = Dict("length" => SkipRequest)

observe_calls(state, kernel, messages, steering, answer, ::Type{SkipRequest}) = observe_skipped(state, kernel, messages, steering, answer, getfield(state, :mode))
observe_skipped(state, kernel, messages, steering, answer, ::Manual) = plan_calls(state, kernel, messages, answer, SkipRequest)
function observe_skipped(state, kernel, messages, steering, answer, ::Automatic)
    for call in answer.calls
        text = "Error: Tool call \"$(call.name)\" was not executed: the response hit the output token limit, so its arguments may be truncated. Re-issue the tool call with complete arguments."
        push!(messages, ToolMessage(call.id, text, true))
    end
    kernel, effect, steering = model(kernel, messages, steering)
    K.Applied(update(state; kernel, messages, steering, phase=WaitingModel), (effect,))
end

observe_calls(state, kernel, messages, steering, answer, ::Type{ToolRequest}) = plan_calls(state, kernel, messages, answer, ToolRequest)

function plan_calls(state, kernel, messages, answer, requesttype)
    effects = K.Pending[]
    for call in answer.calls
        kernel, effect = plan(kernel, requesttype(call))
        push!(effects, effect)
    end
    order = [effect.id for effect in effects]
    calls = deepcopy(answer.calls)
    updated = update(state; kernel, messages, order, calls, phase=WaitingTools)
    K.Applied(updated, Tuple(effects))
end

K.step(state::State, event::K.Observe{ToolReply}) = observe(state, event, observe(state, event, WaitingTools))

function observe(state::State, event::K.Observe{ToolReply}, result::K.Applied)
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
        push!(messages, ToolMessage(call, observation))
        flushed += 1
    end
    if !isempty(kernel.pending)
        return K.Applied(update(state; kernel, messages, flushed), ())
    end
    observed_tools(state, kernel, messages, getfield(state, :mode))
end

observed_tools(state, kernel, messages, ::Manual) = K.Applied(update(state; kernel, messages, order=String[], calls=ToolCall[], flushed=0, phase=ReadyModel), ())
function observed_tools(state, kernel, messages, ::Automatic)
    kernel, effect, steering = model(kernel, messages, getfield(state, :steering))
    updated = update(state; kernel, messages, steering, order=String[], calls=ToolCall[], flushed=0, phase=WaitingModel)
    K.Applied(updated, (effect,))
end

K.step(state::State, event::K.Observe{ModelFailure}) = observe(state, event, observe(state, event, WaitingModel))

function observe(state::State, event::K.Observe{ModelFailure}, result::K.Applied)
    K.Applied(update(state; kernel=result.state, phase=failurephase(getfield(state, :cancellation))), ())
end
failurephase(::Requested) = Cancelled
failurephase(::Active) = Incomplete

K.step(state::State, event::K.Observe) = K.Rejected(state, :observation_type)

end
