import ..JuliaForever: Tool, ToolSet, ToolResult, ToolFailure, Completion, Usage, InvalidResponse, ProviderStatus, ProviderError, UnsupportedImage, name, execute, complete, conversation_reply, modelmessages, attempt, fresh, expose!
import ..Conversation
import ..Kernel
using JSON3

struct Context{P, T}
    provider::P
    tools::T
    parameters::Dict{String, Any}
end

Base.show(io::IO, ::Context) = print(io, "Execution.Context([redacted])")

const contexts = Dict{String, Context}()
const contexts_lock = ReentrantLock()

function install!(id::AbstractString, provider, tools; parameters=Dict())
    context = Context(provider, contexttools(tools), Dict{String, Any}(string(key) => deepcopy(value) for (key, value) in pairs(parameters)))
    lock(contexts_lock) do
        haskey(contexts, String(id)) && return false
        contexts[String(id)] = context
        true
    end
end

contexttools(tools) = Dict{String, Tool}(name(tool) => tool for tool in tools)
contexttools(tools::ToolSet) = fresh(tools)

function uninstall!(id::AbstractString)
    lock(contexts_lock) do
        pop!(contexts, String(id), nothing)
    end
    nothing
end

context(id::String) = lock(() -> contexts[id], contexts_lock)

struct Rejected
    reason::Symbol
end

struct Uncertain{T}
    cause::T
end

struct ModelResult{O <: Kernel.Observation}
    observation::O
    usage::Union{Nothing, Usage}
    error::Union{Nothing, String, InvalidResponse, ProviderStatus, ProviderError, UnsupportedImage}
end

struct Work{T <: Kernel.Effect, R}
    context::String
    effect::T
    result::Type{R}
    exposed::Union{Nothing, Vector{String}}
end

resulttype(detailed::Bool) = (Kernel.Observation, ModelResult)[Int(detailed) + 1]
Work(context::AbstractString, effect::Kernel.Effect, detailed::Bool, exposed=nothing) = Work(String(context), effect, resulttype(detailed), exposed)
Work(context::AbstractString, effect::Kernel.Effect; detailed=false, exposed=nothing) = Work(String(context), effect, detailed, exposed)

isdetailed(::Type{Kernel.Observation}) = false
isdetailed(::Type{ModelResult}) = true
function Base.getproperty(work::Work, name::Symbol)
    name === :detailed && return isdetailed(getfield(work, :result))
    getfield(work, name)
end
Base.propertynames(::Work, private::Bool=false) = (:context, :effect, :detailed, :result, :exposed)

function submit!(executor::Executor, pending::Kernel.Pending, attempt::Integer, context::AbstractString; detailed=false, exposed=nothing, on_handle=nothing)
    submit!(executor, pending, attempt, context, resulttype(detailed); exposed, on_handle)
end
function submit!(executor::Executor, pending::Kernel.Pending, attempt::Integer, context::AbstractString, result::Type; exposed=nothing, on_handle=nothing)
    submit!(executor, pending.id, attempt, Work(String(context), pending.effect, result, exposed); on_handle)
end

struct Turn{T}
    value::T
    models::Vector{ModelResult}
end

reply(response::Completion) = conversation_reply((; message=response.message, result=response, started=false))
reply(message::AbstractDict) = conversation_reply((; message, result=nothing, started=false))
result(response::Union{Completion, AbstractDict}, ::Type{Kernel.Observation}) = reply(response)
result(response::Completion, ::Type{ModelResult}) = ModelResult(reply(response), response.usage, response.error)
result(message::AbstractDict, ::Type{ModelResult}) = ModelResult(reply(message), nothing, nothing)
result(failure::Conversation.ModelFailure, ::Type{Kernel.Observation}) = failure
result(failure::Conversation.ModelFailure, ::Type{ModelResult}) = ModelResult(failure, nothing, nothing)

worktools(tools, ::Nothing) = copy(tools)
function worktools(tools::ToolSet, exposed::Vector{String})
    snapshot = fresh(tools)
    expose!(snapshot, exposed)
    snapshot
end

function perform(work::Work{Conversation.ModelRequest}, cancellation::Cancellation)
    capabilities = context(work.context)
    try
        messages = modelmessages(work.effect.messages)
        tools = worktools(capabilities.tools, work.exposed)
        parameters = deepcopy(capabilities.parameters)
        response = isempty(parameters) ? complete(capabilities.provider, messages, tools) : complete(capabilities.provider, messages, tools; parameters)
        result(response, work.result)
    catch
        failure = Conversation.ModelFailure("provider did not return")
        result(failure, work.result)
    end
end

function perform(work::Work{Conversation.ToolRequest}, cancellation::Cancellation)
    capabilities = context(work.context)
    call = work.effect.call
    tool, args = try
        worktools(capabilities.tools, work.exposed)[call.name], JSON3.read(codeunits(call.arguments))
    catch exception
        return Conversation.ToolReply(ToolFailure(sprint(showerror, exception)))
    end
    Conversation.ToolReply(attempt(() -> execute(tool, args)))
end

function perform(work::Work{Conversation.SkipRequest}, cancellation::Cancellation)
    context(work.context)
    name = work.effect.call.name
    Conversation.ToolReply(ToolFailure("Tool call \"$name\" was not executed: the response hit the output token limit, so its arguments may be truncated. Re-issue the tool call with complete arguments."))
end
