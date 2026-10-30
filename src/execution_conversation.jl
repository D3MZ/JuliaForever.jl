import ..JuliaForever: Tool, ToolResult, ToolFailure, Completion, Usage, InvalidResponse, ProviderStatus, ProviderError, UnsupportedImage, name, execute, complete, conversation_reply, attempt
import ..Conversation
import ..Kernel
using JSON3

struct Context{P}
    provider::P
    tools::Dict{String, Tool}
    parameters::Dict{String, Any}
end

Base.show(io::IO, ::Context) = print(io, "Execution.Context([redacted])")

const contexts = Dict{String, Context}()
const contexts_lock = ReentrantLock()

function install!(id::AbstractString, provider, tools; parameters=Dict())
    context = Context(provider, Dict{String, Tool}(name(tool) => tool for tool in tools), Dict{String, Any}(string(key) => deepcopy(value) for (key, value) in pairs(parameters)))
    lock(contexts_lock) do
        haskey(contexts, String(id)) && return false
        contexts[String(id)] = context
        true
    end
end

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
end

resulttype(detailed::Bool) = (Kernel.Observation, ModelResult)[Int(detailed) + 1]
Work(context::AbstractString, effect::Kernel.Effect, detailed::Bool) = Work(String(context), effect, resulttype(detailed))
Work(context::AbstractString, effect::Kernel.Effect; detailed=false) = Work(String(context), effect, detailed)

isdetailed(::Type{Kernel.Observation}) = false
isdetailed(::Type{ModelResult}) = true
function Base.getproperty(work::Work, name::Symbol)
    name === :detailed && return isdetailed(getfield(work, :result))
    getfield(work, name)
end
Base.propertynames(::Work, private::Bool=false) = (:context, :effect, :detailed, :result)

function submit!(executor::Executor, pending::Kernel.Pending, attempt::Integer, context::AbstractString; detailed=false, on_handle=nothing)
    submit!(executor, pending.id, attempt, Work(context, pending.effect; detailed); on_handle)
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

function perform(work::Work{Conversation.ModelRequest}, cancellation::Cancellation)
    capabilities = context(work.context)
    try
        messages = [convert(Dict{String, Any}, message) for message in work.effect.messages]
        tools = copy(capabilities.tools)
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
        capabilities.tools[call.name], JSON3.read(call.arguments)
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
