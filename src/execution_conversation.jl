import ..JuliaForever: Tool, ToolResult, Completion, name, execute, complete, conversation_reply
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
end

Work(context::AbstractString, effect::Kernel.Effect) = Work(String(context), effect)

function submit!(executor::Executor, pending::Kernel.Pending, attempt::Integer, context::AbstractString)
    submit!(executor, pending.id, attempt, Work(context, pending.effect))
end

reply(response::Completion) = conversation_reply((; message=response.message, result=response, started=false))
reply(message::AbstractDict) = conversation_reply((; message, result=nothing, started=false))

function perform(work::Work{Conversation.ModelRequest}, cancellation::Cancellation)
    capabilities = context(work.context)
    try
        messages = [convert(Dict{String, Any}, message) for message in work.effect.messages]
        tools = copy(capabilities.tools)
        parameters = deepcopy(capabilities.parameters)
        response = isempty(parameters) ? complete(capabilities.provider, messages, tools) : complete(capabilities.provider, messages, tools; parameters)
        reply(response)
    catch
        Conversation.ModelFailure("provider did not return")
    end
end

function perform(work::Work{Conversation.ToolRequest}, cancellation::Cancellation)
    capabilities = context(work.context)
    call = work.effect.call
    result = try
        execute(capabilities.tools[call.name], JSON3.read(call.arguments))
    catch exception
        ToolResult(sprint(showerror, exception), true)
    end
    Conversation.ToolReply(result.text, result.iserror)
end

function perform(work::Work{Conversation.SkipRequest}, cancellation::Cancellation)
    context(work.context)
    name = work.effect.call.name
    Conversation.ToolReply("Tool call \"$name\" was not executed: the response hit the output token limit, so its arguments may be truncated. Re-issue the tool call with complete arguments.", true)
end
