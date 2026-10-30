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

struct Work{T <: Kernel.Effect}
    context::String
    effect::T
    detailed::Bool
end

Work(context::AbstractString, effect::Kernel.Effect; detailed=false) = Work(String(context), effect, detailed)

function submit!(executor::Executor, pending::Kernel.Pending, attempt::Integer, context::AbstractString; detailed=false, on_handle=nothing)
    submit!(executor, pending.id, attempt, Work(context, pending.effect; detailed); on_handle)
end

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

struct Turn{T}
    value::T
    models::Vector{ModelResult}
end

reply(response::Completion) = conversation_reply((; message=response.message, result=response, started=false))
reply(message::AbstractDict) = conversation_reply((; message, result=nothing, started=false))
result(response::Completion, detailed::Bool) = detailed ? ModelResult(reply(response), response.usage, response.error) : reply(response)
result(message::AbstractDict, detailed::Bool) = detailed ? ModelResult(reply(message), nothing, nothing) : reply(message)

function perform(work::Work{Conversation.ModelRequest}, cancellation::Cancellation)
    capabilities = context(work.context)
    try
        messages = [convert(Dict{String, Any}, message) for message in work.effect.messages]
        tools = copy(capabilities.tools)
        parameters = deepcopy(capabilities.parameters)
        response = isempty(parameters) ? complete(capabilities.provider, messages, tools) : complete(capabilities.provider, messages, tools; parameters)
        result(response, work.detailed)
    catch
        failure = Conversation.ModelFailure("provider did not return")
        work.detailed ? ModelResult(failure, nothing, nothing) : failure
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
