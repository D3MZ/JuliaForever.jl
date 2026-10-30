export steer!, followup!, dequeue!, steeringmode!, followupmode!, name!, cancel!, abandon!, continue!

struct Truncated
    completion::Completion
end

abstract type TurnState end
struct Idle <: TurnState end
struct Running <: TurnState end
struct Cancelled <: TurnState end

abstract type ToolMode end
struct Sequential <: ToolMode end
struct Parallel <: ToolMode end
const toolmodes = Dict(:sequential => Sequential(), :parallel => Parallel())
toolmode(mode) = get(toolmodes, mode, nothing)
toolmode(mode::ToolMode) = mode

mutable struct Agent{P, T}
    provider::P
    tools::T
    messages::Vector{Dict{String, Any}}
    initial::Conversation.State
    state::Conversation.State
    events::Vector{Kernel.Event}
    lock::ReentrantLock
    turn::TurnState
    shell::ShellCancellation
    handle::Any
    history::Union{Nothing, History.Store}
    history_revision::Int
    fault::Union{Nothing, History.Rejected}
end

function Agent(provider, tools, messages; history=nothing)
    transcript = Conversation.Message[Conversation.RawMessage(deepcopy(message)) for message in messages]
    initial = Conversation.State("agent-" * randstring(16); automatic=false, messages=transcript)
    openagent(provider, fresh(tools), messages, initial, history)
end

function Agent(provider, tools, messages::Vector{Conversation.Message}; history=nothing)
    initial = Conversation.State("agent-" * randstring(16); automatic=false, messages)
    projected = Dict{String, Any}[convert(Dict{String, Any}, message) for message in messages]
    openagent(provider, fresh(tools), projected, initial, history)
end

Agent(provider, tools; history=nothing) = Agent(provider, Dict{String, Tool}(name(tool) => tool for tool in tools), Dict{String, Any}[]; history)
Agent(provider, tools::ToolSet; history=nothing) = Agent(provider, tools, Dict{String, Any}[]; history)

function withprovider(agent::Agent, provider)
    lock(agent.lock) do
        Agent(provider, agent.tools, agent.messages, agent.initial, agent.state, getfield(agent, :events), agent.lock, agent.turn, agent.shell, agent.handle, agent.history, agent.history_revision, agent.fault)
    end
end

function Base.getproperty(agent::Agent, name::Symbol)
    name === :running && return running(getfield(agent, :turn))
    name === :cancelled && return cancelled(getfield(agent, :turn))
    value = getfield(agent, name)
    name === :events ? deepcopy(value) : value
end

Base.propertynames(agent::Agent, private::Bool=false) = (fieldnames(typeof(agent))..., :running, :cancelled)

function transition!(f, agent::Agent)
    lock(agent.lock) do
        transition!(f, agent, agent.fault)
    end
end

transition!(f, agent::Agent, fault::History.Rejected) = (fault, Conversation.Message[])

function transition!(f, agent::Agent, ::Nothing)
    event = f(agent.state.revision)
    before = length(agent.state.messages)
    transition!(agent, event, before, Kernel.step(agent.state, event))
end

transition!(agent::Agent, event, before, result) = (result, Conversation.Message[])

function transition!(agent::Agent, event, before, result::Kernel.Applied)
    saved = deepcopy(event)
    transition!(agent, saved, before, result, persist!(agent, saved))
end

transition!(agent::Agent, event, before, result, rejected::History.Rejected) = (rejected, Conversation.Message[])

function transition!(agent::Agent, event, before, result::Kernel.Applied, ::Nothing)
    previous = agent.state
    agent.state = result.state
    push!(getfield(agent, :events), event)
    applied!(agent.tools, previous, event, result.state)
    result, result.state.messages[before+1:end]
end

outcome(result::History.Rejected, fallback) = result
outcome(result, fallback) = fallback

"Queue a user message for the next turn."
function steer!(agent::Agent, prompt)
    result, _ = transition!(revision -> Conversation.Steer(revision, prompt), agent)
    outcome(result, nothing)
end

"Queue a user message for when the agent would otherwise stop."
function followup!(agent::Agent, prompt)
    result, _ = transition!(revision -> Conversation.Followup(revision, prompt), agent)
    outcome(result, nothing)
end

const queuemodes = Dict(:one_at_a_time => Conversation.OneAtATime(), :all => Conversation.AllAtOnce())

"Set how many queued steering messages are delivered at each boundary."
function steeringmode!(agent::Agent, mode::Symbol)
    result, _ = transition!(revision -> Conversation.SteeringMode(revision, queuemodes[mode]), agent)
    outcome(result, nothing)
end

"Set how many follow-up messages are delivered when the agent would stop."
function followupmode!(agent::Agent, mode::Symbol)
    result, _ = transition!(revision -> Conversation.FollowupMode(revision, queuemodes[mode]), agent)
    outcome(result, nothing)
end

"Clear and return queued steering and follow-up messages."
function dequeue!(agent::Agent)
    lock(agent.lock) do
        queued = (; steering=agent.state.steering, followups=agent.state.followups)
        dequeue!(agent, queued, agent.fault)
    end
end

dequeue!(agent::Agent, queued, fault::History.Rejected) = fault
function dequeue!(agent::Agent, queued, ::Nothing)
    isempty(queued.steering) && isempty(queued.followups) && return queued
    result, _ = transition!(revision -> Conversation.Dequeue(revision), agent)
    outcome(result, queued)
end

"Set the current session's display name."
function name!(agent::Agent, text::AbstractString)
    result, _ = transition!(revision -> Conversation.SessionName(revision, Conversation.sessionname(text)), agent)
    outcome(result, nothing)
end

"Cancel native provider requests and in-flight Unix shell calls; other work stops at the next boundary."
function cancel!(agent::Agent)
    handle = nothing
    shell = nothing
    try
        lock(agent.lock) do
            cancel!(agent, agent.turn) do currenthandle, currentshell
                handle = currenthandle
                shell = currentshell
            end
        end
    finally
        cancel!(shell)
        cancelhandle!(handle)
    end
end

cancelhandle!(handle) = Execution.cancel!(handle)
cancelhandle!(context::HTTP.RequestContext) = HTTP.cancel!(context)

cancel!(f, agent::Agent, ::Idle) = false

function cancel!(f, agent::Agent, ::Union{Running, Cancelled})
    try
        result, _ = transition!(revision -> Conversation.Cancel(revision), agent)
        outcome(result, true)
    finally
        agent.turn = Cancelled()
        f(agent.handle, agent.shell)
    end
end

running(::Idle) = false
running(::Union{Running, Cancelled}) = true
cancelled(::Union{Idle, Running}) = false
cancelled(::Cancelled) = true
cancelled(agent::Agent) = lock(() -> cancelled(agent.turn), agent.lock)

begin!(agent::Agent) = began(startturn!(agent))
begin!(agent::Agent, turn::TurnState) = began(startturn!(agent, turn))
began(::Nothing) = false
began(::Running) = true

function startturn!(agent::Agent)
    lock(agent.lock) do
        startturn!(agent, agent.turn)
    end
end

startturn!(agent::Agent, ::Union{Running, Cancelled}) = nothing

function startturn!(agent::Agent, ::Idle)
    agent.turn = Running()
    agent.shell = ShellCancellation()
    agent.turn
end

text(value::AbstractString) = String(value)
text(value) = nothing

function Base.convert(::Type{Conversation.ToolCall}, call::AbstractDict)
    info = callinfo(call)
    Conversation.ToolCall(String(call["id"]), text(info.name), text(info.args); metadata=call)
end

function Base.convert(::Type{Dict{String, Any}}, message::Conversation.User)
    Dict{String, Any}("role" => "user", "content" => message.content)
end

function Base.convert(::Type{Dict{String, Any}}, message::Conversation.ImageUser)
    images = [Dict("mime" => image.mime, "data" => image.data) for image in message.images]
    Dict{String, Any}("role" => "user", "content" => message.content, "images" => images)
end

function Base.convert(::Type{Dict{String, Any}}, message::Conversation.Assistant)
    value = deepcopy(message.metadata)
    value["role"] = "assistant"
    value["content"] = message.content
    if !isempty(message.calls)
        value["tool_calls"] = [convert(Dict{String, Any}, call) for call in message.calls]
    end
    value
end

function Base.convert(::Type{Dict{String, Any}}, call::Conversation.ToolCall)
    isempty(call.metadata) || return deepcopy(call.metadata)
    Dict{String, Any}("id" => call.id, "type" => "function", "function" => Dict("name" => call.name, "arguments" => call.arguments))
end

function Base.convert(::Type{Dict{String, Any}}, message::Conversation.ToolMessage)
    value = Dict{String, Any}("role" => "tool", "tool_call_id" => message.id, "content" => message.content, "is_error" => message.iserror)
    attach!(value, message.image)
end

attach!(value, ::Nothing) = value

function attach!(value, image::Image)
    value["image"] = Dict("mime" => image.mime, "data" => image.data)
    value
end

Base.convert(::Type{Dict{String, Any}}, message::Conversation.RawMessage) = deepcopy(message.value)
Base.convert(::Type{Dict{String, Any}}, message::Conversation.SkillContext) = Dict{String, Any}("role" => "system", "content" => message.content)

function Base.convert(::Type{Dict{String, Any}}, message::Conversation.BashMessage)
    value = Dict{String, Any}("role" => "bashExecution", "command" => message.command, "output" => message.output, "cancelled" => Conversation.bashcancelled(message.status), "truncated" => Conversation.bashtruncated(message.extent), "timestamp" => message.timestamp)
    bashfield!(value, "exitCode", message.exitcode)
    bashfield!(value, "fullOutputPath", message.file)
    bashfield!(value, "excludeFromContext", Conversation.bashexcluded(message.context))
end

bashfield!(value, key, ::Nothing) = value
bashfield!(value, key, field) = (value[key] = field; value)

function modelmessages(messages)
    result = Dict{String, Any}[]
    foreach(message -> modelmessage!(result, message), messages)
    result
end
modelmessage!(messages, value::Conversation.Message) = push!(messages, convert(Dict{String, Any}, value))
modelmessage!(messages, value::Conversation.BashMessage{Conversation.ExcludedBashContext}) = messages
function modelmessage!(messages, value::Conversation.BashMessage)
    push!(messages, Dict{String, Any}("role" => "user", "content" => bashtext(value)))
end
function bashtext(message::Conversation.BashMessage)
    content = isempty(message.output) ? "(no output)" : "```\n$(message.output)\n```"
    status = bashstatus(message.status, message.exitcode)
    truncation = bashtruncation(message.extent, message.file)
    "Ran `$(message.command)`\n$content$status$truncation"
end
bashexit(::Nothing) = ""
const bashcodes = Dict(0 => "")
bashexit(code::Int) = get(bashcodes, code, "\n\nCommand exited with code $code")
bashstatus(::Conversation.FinishedBash, code) = bashexit(code)
bashstatus(::Conversation.CancelledBash, code) = "\n\n(command cancelled)"
bashtruncation(::Conversation.FullBash, file) = ""
bashtruncation(::Conversation.TruncatedBash, ::Nothing) = ""
bashtruncation(::Conversation.TruncatedBash, file::String) = "\n\n[Output truncated. Full output: $file]"

function recordbash!(agent::Agent, message::Conversation.BashMessage)
    lock(agent.lock) do
        result, _ = transition!(revision -> Conversation.BashOutput(revision, message), agent)
        recordbash!(agent, message, result)
    end
end
recordbash!(agent, message, result) = result
function recordbash!(agent, message, result::Kernel.Applied)
    push!(agent.messages, convert(Dict{String, Any}, message))
    nothing
end

synccontext(current, ::Conversation.Message) = current
synccontext(current, message::Conversation.SkillContext) = message
syncmessage!(messages, value, ::Nothing) = (push!(messages, Conversation.RawMessage(deepcopy(value))); nothing)
function syncmessage!(messages, value, previous::Conversation.SkillContext)
    if Kernel.same(value, convert(Dict{String, Any}, previous))
        push!(messages, previous)
        return nothing
    end
    push!(messages, Conversation.RawMessage(deepcopy(value)))
    previous
end
function syncmessages(values, previous)
    context = foldl(synccontext, previous; init=nothing)
    messages = Conversation.Message[]
    for value in values
        context = syncmessage!(messages, value, context)
    end
    messages
end

function sync!(agent::Agent)
    result = lock(agent.lock) do
        previous = agent.state.messages
        recorded = Dict{String, Any}[convert(Dict{String, Any}, message) for message in previous]
        if !Kernel.same(recorded, agent.messages)
            history = syncmessages(agent.messages, previous)
            result, _ = transition!(revision -> Conversation.History(revision, history), agent)
            return outcome(result, nothing)
        end
        nothing
    end
    result
end

function finish!(agent::Agent)
    lock(agent.lock) do
        agent.turn = Idle()
    end
end

name(::Read) = "read"
name(::Write) = "write"
name(::Edit) = "edit"

schema(::Read) = Dict("type" => "object", "properties" => Dict("path" => Dict("type" => "string"), "offset" => Dict("type" => "integer"), "limit" => Dict("type" => "integer")), "required" => ["path"])
schema(::Write) = Dict("type" => "object", "properties" => Dict("path" => Dict("type" => "string"), "content" => Dict("type" => "string")), "required" => ["path", "content"])
schema(::Edit) = Dict("type" => "object", "properties" => Dict("path" => Dict("type" => "string"), "edits" => Dict("type" => "array", "items" => Dict("type" => "object", "properties" => Dict("oldText" => Dict("type" => "string"), "newText" => Dict("type" => "string")), "required" => ["oldText", "newText"]))), "required" => ["path", "edits"])

description(::Read) = "Read a text file or a PNG/JPEG image up to 10 MiB. Offset and limit are line based for text."
description(::Write) = "Create or overwrite a text file."
description(::Edit) = "Replace unique, non-overlapping text in a file."

definition(tool) = Dict("type" => "function", "function" => Dict("name" => name(tool), "description" => description(tool), "parameters" => schema(tool)))

invoke(tool::Tool, args, ::ShellCancellation, update) = execute(tool, args)
invoke(tool::ToolSearch, args, ::ShellCancellation, update) = search(tool, args)
invoke(tool::Union{Bash, PowerShell}, args, cancel::ShellCancellation, update) = execute(tool, args; cancel, on_update=update)

function prepare(agent::Agent, call, callback)
    tool, args = try
        tool = call["function"]
        agent.tools[tool["name"]], JSON3.read(codeunits(tool["arguments"]))
    catch exception
        return ToolFailure(sprint(showerror, exception))
    end
    input = JSON3.read(codeunits(JSON3.write(args)), Dict{String, Any})
    before = try
        interceptcall(callback, call, input)
    catch exception
        return ToolFailure(sprint(showerror, exception))
    end
    prepare(tool, input, before, turnstate(agent))
end

prepare(tool, input, before, ::Cancelled) = ToolFailure("Operation cancelled")
prepare(tool, input, before, ::Union{Idle, Running}) = prepare(tool, input, before)

interceptcall(callback, call, input) = nothing
prepare(tool::Tool, input, ::Nothing) = (; tool, input)
invoke(agent, call, update, callback) = invoke(agent, call, prepare(agent, call, callback), update, callback)
invoke(agent, call, result::ToolResult, update, callback) = result
invoke(agent, call, plan::NamedTuple, update, callback) = runprepared(agent, call, plan.tool, plan.input, update, callback)
function runprepared(agent, call, tool, input, update, callback)
    args = JSON3.read(codeunits(JSON3.write(input)))
    result = attempt(() -> invoke(tool, args, agent.shell, update))
    interceptresult(callback, call, args, result)
end

interceptresult(callback, call, args, result) = result

struct EventSink{F}
    lock::ReentrantLock
    callback::F
end
(sink::EventSink)(event) = lock(() -> emit(sink.callback, event), sink.lock)
interceptcall(sink::EventSink, call, input) = lock(() -> interceptcall(sink.callback, call, input), sink.lock)
interceptresult(sink::EventSink, call, args, result) = lock(() -> interceptresult(sink.callback, call, args, result), sink.lock)

emit(::Nothing, event) = nothing
emit(callback, event) = callback(event)

abstract type MessagePresentation end
struct Unannounced <: MessagePresentation end
struct Announced <: MessagePresentation end

message_start!(callback, message, ::Unannounced) = emit(callback, (; type=:message_start, message=deepcopy(message)))
message_start!(callback, message, ::Announced) = nothing

function record!(agent, message, messages, on_agent_event; started=Unannounced())
    message_start!(on_agent_event, message, started)
    push!(agent.messages, message)
    push!(messages, message)
    emit(on_agent_event, (; type=:message_end, message=deepcopy(message)))
end

function present!(agent, added, messages, on_agent_event; started=Unannounced())
    for (index, message) in enumerate(added)
        record!(agent, convert(Dict{String, Any}, message), messages, on_agent_event; started=index == 1 ? started : Unannounced())
    end
end

abstract type AgentUpdate end
struct AgentText <: AgentUpdate
    event
end
struct AgentThinking <: AgentUpdate
    event
end
struct AgentToolCall <: AgentUpdate
    event
end

const agentupdates = Dict(:text => AgentText, :thinking => AgentThinking, :tool_call => AgentToolCall)
agentupdate(event) = agentupdate(get(agentupdates, event.type, Nothing), event)
agentupdate(::Type{Nothing}, event) = nothing
agentupdate(::Type{T}, event) where {T <: AgentUpdate} = T(event)

function update!(partial, calls, update::AgentText)
    event = update.event
    partial["content"] = appendtext(partial["content"], event.text)
end

function update!(partial, calls, update::AgentThinking)
    event = update.event
    partial["reasoning_content"] = get(partial, "reasoning_content", "") * event.text
end

function update!(partial, calls, update::AgentToolCall)
    event = update.event
    if !haskey(calls, event.index)
        calls[event.index] = Dict("id" => "", "type" => "function", "function" => Dict("name" => "", "arguments" => ""))
        push!(get!(partial, "tool_calls", []), calls[event.index])
    end
    call = calls[event.index]
    writeonce!(call, "id", event.id)
    writeonce!(call["function"], "name", event.name)
    call["function"]["arguments"] *= event.arguments
end

publish!(partial, calls, started, on_agent_event, ::Nothing) = nothing

publish!(partial, calls, started, on_agent_event, update::AgentUpdate) = publish!(partial, calls, started, on_agent_event, update, started[])
function publish!(partial, calls, started, on_agent_event, update::AgentUpdate, ::Unannounced)
    message_start!(on_agent_event, partial, Unannounced())
    started[] = Announced()
    publish!(partial, calls, started, on_agent_event, update, Announced())
end
function publish!(partial, calls, started, on_agent_event, update::AgentUpdate, ::Announced)
    update!(partial, calls, update)
    emit(on_agent_event, (; type=:message_update, assistant_event=update.event, message=deepcopy(partial)))
end

response(message::Completion) = (; message=message.message, result=message, started=Unannounced())
response(message) = (; message, result=nothing, started=Unannounced())

const contextkey = gensym(:context_messages)
withcontext(f, messages) = task_local_storage(f, contextkey, messages)

register!(agent::Agent, ::Nothing) = nothing

function register!(agent::Agent, context::HTTP.RequestContext)
    turn, failure = lock(agent.lock) do
        agent.handle = context
        agent.turn, agent.fault
    end
    register!(context, turn, failure)
end

register!(context::HTTP.RequestContext, ::Union{Idle, Running}, ::Nothing) = nothing
register!(context::HTTP.RequestContext, ::Union{Idle, Running}, ::History.Rejected) = HTTP.cancel!(context)
register!(context::HTTP.RequestContext, ::Cancelled, failure) = HTTP.cancel!(context)
unregister!(agent::Agent, ::Nothing) = nothing
unregister!(agent::Agent, context::HTTP.RequestContext) = lock(() -> (agent.handle = nothing), agent.lock)

requestcancelled(::HTTP.CanceledError, ::Cancelled) = true
requestcancelled(exception, turn) = false

function request!(f, agent::Agent, partial, started)
    context = requestcontext(agent.provider)
    register!(agent, context)
    depth = length(current_exceptions())
    try
        task_local_storage(f, requestkey, context)
    finally
        unregister!(agent, context)
        exceptions = current_exceptions()
        if length(exceptions) > depth && requestcancelled(last(exceptions).exception, turnstate(agent))
            result = Completion(deepcopy(partial), nothing, "cancelled", Unfinished(), "cancelled")
            return (; message=result.message, result, started=started[])
        end
    end
end

function response(agent, request, parameters, ::Nothing, on_agent_event)
    partial = Dict{String, Any}("role" => "assistant", "content" => nothing)
    info = responseinfo(agent.provider, round(Int, 1000time()))
    result = request!(agent, partial, Ref{MessagePresentation}(Unannounced())) do
        message = isempty(parameters) ? complete(agent.provider, request.messages, request.tools) : complete(agent.provider, request.messages, request.tools; parameters)
        message = price(agent.provider, message)
        response(message)
    end
    merge(result, (; info))
end

providercomplete!(callback, result) = nothing

function response(agent, request, parameters, on_event, on_agent_event)
    partial = Dict{String, Any}("role" => "assistant", "content" => nothing)
    calls = Dict{Any, Any}()
    started = Ref{MessagePresentation}(Unannounced())
    callback = event -> begin
        priced = priceevent(agent.provider, event)
        on_event(priced)
        publish!(partial, calls, started, on_agent_event, agentupdate(priced))
    end
    info = responseinfo(agent.provider, round(Int, 1000time()))
    answer = request!(agent, partial, started) do
        result = price(agent.provider, stream(agent.provider, request.messages, request.tools; parameters, on_event=callback))
        providercomplete!(on_event, result)
        (; message=result.message, result, started=started[])
    end
    merge(answer, (; info))
end

function callinfo(call)
    try
        fn = call["function"]
        (; name=get(fn, "name", nothing), args=get(fn, "arguments", nothing))
    catch
        (; name=nothing, args=nothing)
    end
end

function toolstart(call, on_agent_event)
    info = callinfo(call)
    emit(on_agent_event, (; type=:tool_execution_start, tool_call_id=call["id"], tool_name=info.name, args=info.args))
end

invoke(agent, call, ::Conversation.ToolRequest, ::Union{Idle, Running}, update, callback) = invoke(agent, call, update, callback)
invoke(agent, call, ::Conversation.SkipRequest, ::Union{Idle, Running}, update, callback) = ToolFailure("Tool call \"$(callinfo(call).name)\" was not executed: the response hit the output token limit, so its arguments may be truncated. Re-issue the tool call with complete arguments.")
invoke(agent, call, ::Union{Conversation.ToolRequest, Conversation.SkipRequest}, ::Cancelled, update, callback) = ToolFailure("Operation cancelled")

function toolresult(agent, call, request, on_agent_event)
    info = callinfo(call)
    id = call["id"]
    turn = lock(() -> agent.turn, agent.lock)
    update = partial_result -> emit(on_agent_event, (; type=:tool_execution_update, tool_call_id=id, tool_name=info.name, args=info.args, partial_result))
    result = invoke(agent, call, request, turn, update, on_agent_event)
    toolend(call, result, on_agent_event)
end

function toolend(call, result, on_agent_event)
    info = callinfo(call)
    id = call["id"]
    emit(on_agent_event, (; type=:tool_execution_end, tool_call_id=id, tool_name=info.name, result=visible(result), iserror=result.iserror))
    result
end

toolmessage(call, result::ToolResult) = convert(Dict{String, Any}, Conversation.ToolMessage(call["id"], content(result), result.iserror, result.image))

function toolobserve!(agent, effect, result, messages, on_agent_event)
    transition, added = transition!(revision -> Kernel.Observe(revision, effect.id, Conversation.ToolReply(result)), agent)
    present!(agent, added, messages, on_agent_event)
    transition
end

toolmode(mode::Sequential, effect) = mode
toolmode(mode::Parallel, ::Conversation.ToolRequest) = mode
toolmode(::Parallel, effect) = Sequential()
batchmode(effects) = foldl((mode, effect) -> toolmode(mode, effect.effect), effects; init=Parallel())

runtools!(agent, effects, messages, on_agent_event; tool_execution=:sequential) = runtools!(agent, effects, messages, on_agent_event, toolmode(tool_execution))

function runtools!(agent, effects, messages, on_agent_event, ::Union{Sequential, Nothing})
    results = Dict{String, Any}[]
    calls = [convert(Dict{String, Any}, effect.effect.call) for effect in effects]
    for (effect, call) in zip(effects, calls)
        toolstart(call, on_agent_event)
        result = toolresult(agent, call, effect.effect, on_agent_event)
        toolobserve!(agent, effect, result, messages, on_agent_event)
        push!(results, toolmessage(call, result))
    end
    results
end

runtools!(agent, effects, messages, on_agent_event, ::Parallel) = runtoolsparallel!(agent, effects, messages, on_agent_event, batchmode(effects))
runtoolsparallel!(agent, effects, messages, on_agent_event, mode::Sequential) = runtools!(agent, effects, messages, on_agent_event, mode)
runtoolsparallel!(agent, effects, messages, on_agent_event, ::Parallel) = parallel!(agent, preflight(agent, effects, on_agent_event), messages, on_agent_event)

preflight(agent, effects, callback) = foldl((plans, effect) -> preflight(agent, effect, callback, plans), effects; init=Any[])
preflight(agent, effect, callback, rejected::History.Rejected) = rejected
function preflight(agent, effect, callback, plans::Vector)
    call = convert(Dict{String, Any}, effect.effect.call)
    toolstart(call, callback)
    preflight(agent, effect, callback, plans, call, fault(agent))
end
preflight(agent, effect, callback, plans, call, rejected::History.Rejected) = rejected
function preflight(agent, effect, callback, plans, call, ::Nothing)
    plan = prepare(agent, call, effect.effect, turnstate(agent), callback)
    preflight(agent, effect, callback, plans, call, plan, fault(agent))
end
preflight(agent, effect, callback, plans, call, plan, rejected::History.Rejected) = rejected
function preflight(agent, effect, callback, plans, call, plan, ::Nothing)
    preparedevent(call, plan, callback)
    push!(plans, (; effect, call, plan))
end

prepare(agent, call, ::Conversation.ToolRequest, ::Union{Idle, Running}, callback) = prepare(agent, call, callback)
prepare(agent, call, ::Conversation.SkipRequest, ::Union{Idle, Running}, callback) = ToolFailure("Tool call \"$(callinfo(call).name)\" was not executed: the response hit the output token limit, so its arguments may be truncated. Re-issue the tool call with complete arguments.")
prepare(agent, call, ::Union{Conversation.ToolRequest, Conversation.SkipRequest}, ::Cancelled, callback) = ToolFailure("Operation cancelled")
preparedevent(call, plan::NamedTuple, callback) = nothing
preparedevent(call, result::ToolResult, callback) = toolend(call, result, callback)

parallelresult(agent, item, callback) = parallelresult(agent, item, callback, fault(agent))
parallelresult(agent, item, callback, rejected::History.Rejected) = rejected
parallelresult(agent, item, callback, ::Nothing) = parallelresult(agent, item, callback, item.plan, turnstate(agent))
parallelresult(agent, item, callback, result::ToolResult, turn) = result
parallelresult(agent, item, callback, plan::NamedTuple, ::Cancelled) = toolend(item.call, ToolFailure("Operation cancelled"), callback)
function parallelresult(agent, item, callback, plan::NamedTuple, ::Union{Idle, Running})
    call = item.call
    info = callinfo(call)
    update = partial_result -> emit(callback, (; type=:tool_execution_update, tool_call_id=call["id"], tool_name=info.name, args=info.args, partial_result))
    toolend(call, invoke(agent, call, plan, update, callback), callback)
end

parallel!(agent, rejected::History.Rejected, messages, callback) = rejected
function parallel!(agent, plans::Vector, messages, callback)
    completed = Vector{Any}(undef, length(plans))
    tasks = Vector{Task}(undef, length(plans))
    ready = Channel{Int}(length(plans))
    added = Conversation.Message[]
    failure = nothing
    @sync begin
        for i in eachindex(plans)
            tasks[i] = Threads.@spawn try
                parallelresult(agent, plans[i], callback)
            finally
                put!(ready, i)
            end
        end
        for _ in eachindex(plans)
            i = take!(ready)
            completed[i] = fetch(tasks[i])
            failure = parallelobserve!(agent, plans[i], completed[i], added, failure)
        end
    end
    parallelfinish!(agent, plans, completed, added, messages, callback, failure)
end

parallelobserve!(agent, plan, result, added, rejected) = rejected
parallelobserve!(agent, plan, rejected::History.Rejected, added, ::Nothing) = rejected
function parallelobserve!(agent, plan, result::ToolResult, added, ::Nothing)
    transition, visible = transition!(revision -> Kernel.Observe(revision, plan.effect.id, Conversation.ToolReply(result)), agent)
    parallelobserve!(transition, added, visible)
end
parallelobserve!(transition, added, visible) = transition
function parallelobserve!(::Kernel.Applied, added, visible)
    append!(added, visible)
    nothing
end

parallelfinish!(agent, plans, completed, added, messages, callback, rejected) = rejected
function parallelfinish!(agent, plans, completed, added, messages, callback, ::Nothing)
    presentation = Ref{MessagePresentation}(Unannounced())
    try
        present!(agent, added, messages, callback)
        presentation[] = Announced()
    finally
        preserve!(agent, presentation[])
    end
    [toolmessage(plan.call, result) for (plan, result) in zip(plans, completed)]
end

preserve!(agent, ::Announced) = nothing
function preserve!(agent, ::Unannounced)
    lock(agent.lock) do
        empty!(agent.messages)
        append!(agent.messages, [convert(Dict{String, Any}, message) for message in agent.state.messages])
    end
end

function conversation_reply(answer)
    message = answer.message
    calls = Conversation.ToolCall[convert(Conversation.ToolCall, call) for call in get(message, "tool_calls", [])]
    reply = conversation_reply(message, calls, answer.result)
    responseinfo(reply, get(answer, :info, nothing), answer.result)
end

conversation_reply(message, calls, ::Nothing) = Conversation.ModelReply(Conversation.Assistant(get(message, "content", nothing), calls, nothing, true; metadata=message))
conversation_reply(message, calls, result::Completion) = Conversation.ModelReply(Conversation.Assistant(get(message, "content", nothing), calls, result.finish, getfield(result, :status); metadata=message))
conversation_reply(message, calls, result) = Conversation.ModelReply(Conversation.Assistant(get(message, "content", nothing), calls, result.finish, result.done; metadata=message))

responseinfo(reply::Conversation.ModelReply, ::Nothing, result) = reply
responseinfo(reply::Conversation.ModelReply, ::Nothing, result::Completion) = responseinfo(reply, Conversation.ResponseInfo(result.usage, nothing, nothing, nothing, nothing))
responseinfo(reply::Conversation.ModelReply, info::Conversation.ResponseInfo, result) = responseinfo(reply, info)
responseinfo(reply::Conversation.ModelReply, info::Conversation.ResponseInfo, result::Completion) = responseinfo(reply, Conversation.ResponseInfo(result.usage, info.api, info.provider, info.model, info.timestamp))
function responseinfo(reply::Conversation.ModelReply, info::Conversation.ResponseInfo)
    message = reply.message
    Conversation.ModelReply(Conversation.Assistant(message.content, message.calls, message.finish, getfield(message, :status), message.metadata, info))
end

finish(message, result) = message["content"]
const finishresults = Dict("length" => Truncated)
finish(message, result::Completion) = finish(message, result, get(finishresults, result.finish, nothing))
finish(message, result::Completion, ::Nothing) = message["content"]
finish(message, result::Completion, ::Type{Truncated}) = Truncated(result)

function modelresponse(agent, effect, parameters, on_event, on_agent_event)
    answer = nothing
    try
        request = requestview(on_agent_event, effect.effect.messages, agent.tools, agent.provider)
        received = modelresponse(agent, effect, request, parameters, on_event, on_agent_event, turnstate(agent))
        remembermodel!(received)
        answer = received
    finally
        modelreturned!(agent, effect, answer)
    end
end

modelresponse(agent, effect, request, parameters, on_event, on_agent_event, ::Cancelled) = Cancelled()
function modelresponse(agent, effect, request, parameters, on_event, on_agent_event, ::Union{Idle, Running})
    withcontext(effect.effect.messages) do
        response(agent, request, parameters, on_event, on_agent_event)
    end
end
remembermodel!(::Cancelled) = nothing
remembermodel!(answer::NamedTuple) = rememberusage!(answer.result)
modelreturned!(agent, effect, ::NamedTuple) = nothing
modelreturned!(agent, effect, ::Cancelled) = nothing
modelreturned!(agent, effect, ::Nothing) = transition!(revision -> Kernel.Observe(revision, effect.id, Conversation.ModelFailure("provider did not return")), agent)

interrupt!(agent::Agent, ::Conversation.Phase) = nothing
interrupt!(agent::Agent, ::Union{Conversation.ReadyModelPhase, Conversation.ReadyDecisionPhase, Conversation.WaitingModelPhase, Conversation.WaitingToolsPhase}) = transition!(revision -> Conversation.Interrupt(revision, "turn interrupted"), agent)

"""
    respond!(agent, prompt; on_event=nothing, on_agent_event=nothing, parameters=Dict(), tool_execution=nothing, executor=nothing, context=nothing)

Run a turn and queued messages. `on_event` receives provider stream events; `on_agent_event` receives lifecycle events. Local tool calls run in parallel by default; set `tool_execution=:sequential` to run them in order. Executor-backed turns default to sequential execution. Returns `:busy` for an overlapping run and `:cancelled` for cooperative cancellation. Providers returning a `Completion` retain finish metadata; a custom provider returning only a message cannot report truncation.

Supplying `executor` and `context` selects the executor-backed path, including for a recorded agent. It returns an `Execution.Turn` with the outcome and per-model usage and error metadata; unsupported combinations return `Execution.Rejected` before starting. See `docs/execution.md` for its limitations.
"""
function respond!(agent::Agent, prompt; on_event=nothing, on_agent_event=nothing, parameters=Dict(), tool_execution=nothing, executor=nothing, context=nothing, auto_compaction=nothing, summarize=Summarizer(agent.provider))
    tool_execution = defaultmode(tool_execution, executor)
    used = Ref{Union{Nothing, Usage}}(nothing)
    result = task_local_storage(:jf_pre_compaction, (auto_compaction, summarize)) do
        task_local_storage(:jf_compaction_usage, used) do
            task_local_storage(:jf_overflow_recovery, recovery(auto_compaction, summarize, agent.provider)) do
                respond!(agent, prompt, executor, context; on_event, on_agent_event, parameters, tool_execution)
            end
        end
    end
    finishauto!(agent, result, used[], auto_compaction, summarize, on_agent_event)
    result
end

defaultmode(::Nothing, ::Nothing) = :parallel
defaultmode(::Nothing, executor) = :sequential
defaultmode(mode, executor) = mode

respond!(agent::Agent, prompt, executor, context; kwargs...) = respond_execution!(agent, prompt, executor, context; kwargs...)
respond!(agent::Agent, prompt, ::Nothing, ::Nothing; kwargs...) = respond!(agent, prompt, agent.history; kwargs...)
respond!(agent::Agent, prompt, ::History.Store; kwargs...) = respond_recorded!(agent, prompt; kwargs...)

respond!(agent::Agent, prompt, ::Nothing; on_event, on_agent_event, parameters, tool_execution) = direct_start!(agent, prompt, startturn!(agent); on_event, on_agent_event, parameters, tool_execution)
direct_start!(agent, prompt, ::Nothing; kwargs...) = :busy
function direct_start!(agent, prompt, ::Running; on_event, on_agent_event, parameters, tool_execution)
    messages = Dict{String, Any}[]
    on_agent_event = EventSink(ReentrantLock(), on_agent_event)
    run = (; agent, on_event, callback=on_agent_event, parameters, tool_execution, messages)
    try
        precompact!(agent, on_agent_event)
        try
            emit(on_agent_event, (; type=:agent_start))
            emit(on_agent_event, (; type=:turn_start))
            direct_begin!(run, prompt)
        finally
            interrupt!(agent, agent.state.phase)
            sync!(agent)
            emit(on_agent_event, (; type=:agent_end, messages=deepcopy(messages)))
        end
    finally
        finish!(agent)
    end
end

function direct_begin!(run, prompt)
    agent = run.agent
    sync!(agent)
    _, added = transition!(revision -> Conversation.Input(revision, prompt), agent)
    present!(agent, added, run.messages, run.callback)
    direct_cancel!(run, turnstate(agent))
    sync!(agent)
    next, added = transition!(revision -> Conversation.Advance(revision), agent)
    present!(agent, added, run.messages, run.callback)
    direct_ready!(run, next, turnstate(agent))
end

cancel_transition!(agent, ::Union{Idle, Running}) = nothing
cancel_transition!(agent, ::Cancelled) = cancel_transition!(agent, getfield(agent.state, :cancellation))
cancel_transition!(agent, ::Conversation.Requested) = nothing
function cancel_transition!(agent, ::Conversation.Active)
    result, _ = transition!(revision -> Conversation.Cancel(revision), agent)
    result
end

direct_cancel!(run, turn) = (cancel_transition!(run.agent, turn); nothing)

function direct_ready!(run, next, ::Cancelled)
    emit(run.callback, (; type=:turn_end, message=nothing, tool_results=Dict{String, Any}[]))
    :cancelled
end
direct_ready!(run, next, ::Union{Idle, Running}) = direct_loop!(run, only(next.effects))

function direct_loop!(run, effect)
    pending = Kernel.Pending[effect]
    result = Ref{Any}()
    while !isempty(pending)
        next = direct_step!(run, pop!(pending), turnstate(run.agent))
        schedule_pending!(pending, result, next)
    end
    result[]
end

function direct_step!(run, effect, ::Cancelled)
    transition!(revision -> Kernel.Observe(revision, effect.id, Conversation.ModelFailure("cancelled before dispatch")), run.agent)
    emit(run.callback, (; type=:turn_end, message=nothing, tool_results=Dict{String, Any}[]))
    :cancelled
end

function direct_step!(run, effect, ::Union{Idle, Running})
    answer = modelresponse(run.agent, effect, run.parameters, run.on_event, run.callback)
    direct_answer!(run, effect, answer)
end
direct_answer!(run, effect, ::Cancelled) = direct_step!(run, effect, Cancelled())
function direct_answer!(run, effect, answer)
    outcome = conversation_reply(answer)
    result, added = transition!(revision -> Kernel.Observe(revision, effect.id, outcome), run.agent)
    direct_result!(run, answer, result, added, answer.result)
end

direct_result!(run, answer, transition, added, ::Nothing) = direct_complete!(run, answer, transition, added)
direct_result!(run, answer, transition, added, result::Completion) = direct_result!(run, answer, transition, added, result, getfield(result, :status))
direct_result!(run, answer, transition, added, result) = direct_result!(run, answer, transition, added, result, completionstatus(result.done))
direct_result!(run, answer, transition, added, result, ::Finished) = direct_complete!(run, answer, transition, added)
direct_result!(run, answer, transition, added, result, ::Unfinished) = direct_partial!(run, answer, result)

function direct_partial!(run, answer, result)
    message_start!(run.callback, answer.message, answer.started)
    emit(run.callback, (; type=:message_end, message=deepcopy(answer.message)))
    emit(run.callback, (; type=:turn_end, message=deepcopy(answer.message), tool_results=Dict{String, Any}[]))
    recover!(run, result, turnstate(run.agent))
end

function direct_complete!(run, answer, transition, added)
    agent = run.agent
    message = answer.message
    present!(agent, added, run.messages, run.callback; started=answer.started)
    results = runtools!(agent, transition.effects, run.messages, run.callback; tool_execution=run.tool_execution)
    emit(run.callback, (; type=:turn_end, message=deepcopy(message), tool_results=deepcopy(results)))
    sync!(agent)
    precompactnext!(agent, run.callback)
    next, added = transition!(revision -> Conversation.Advance(revision), agent)
    direct_next!(run, message, answer.result, next, added, turnstate(agent))
end

direct_next!(run, message, completion, next, added, ::Cancelled) = :cancelled
function direct_next!(run, message, completion, next, added, ::Union{Idle, Running})
    isempty(next.effects) && return finish(message, completion)
    emit(run.callback, (; type=:turn_start))
    present!(run.agent, added, run.messages, run.callback)
    only(next.effects)
end

"Continue a transcript ending in a user or tool message. Returns :empty or :assistant_tail for unsupported tails."
function continue!(agent::Agent; on_event=nothing, on_agent_event=nothing, parameters=Dict(), tool_execution=:parallel, auto_compaction=nothing, summarize=Summarizer(agent.provider))
    used = Ref{Union{Nothing, Usage}}(nothing)
    result = task_local_storage(:jf_pre_compaction, (auto_compaction, summarize)) do
        task_local_storage(:jf_compaction_usage, used) do
            task_local_storage(:jf_overflow_recovery, recovery(auto_compaction, summarize, agent.provider)) do
                selected = lock(agent.lock) do
                    continue_start!(agent, agent.turn, agent.fault, toolmode(tool_execution))
                end
                continue_selected!(agent, selected; on_event, on_agent_event, parameters, tool_execution)
            end
        end
    end
    finishauto!(agent, result, used[], auto_compaction, summarize, on_agent_event)
    result
end
continue_start!(agent, ::Union{Running, Cancelled}, fault, mode) = :busy
continue_start!(agent, ::Idle, fault::History.Rejected, mode) = fault
continue_start!(agent, ::Idle, ::Nothing, mode) = continue_tail!(agent, agent.history, mode)
continue_tail!(agent, history::History.Store, mode) = History.Rejected(:unsupported_execution)
continue_tail!(agent, history::History.Store, ::Union{Sequential, Parallel}) = continue_tail!(agent)
continue_tail!(agent, ::Nothing, mode) = continue_tail!(agent)
struct SystemTail end
const continuationroles = Dict("system" => SystemTail(), "assistant" => Conversation.ContinueQueued)
continuationkind(::Nothing, ::SystemTail) = nothing
continuationkind(state, ::SystemTail) = Conversation.Continue
continuationkind(state, kind::Type{<:Union{Conversation.Continue, Conversation.ContinueQueued}}) = kind
continuationkind(state, message::AbstractDict) = continuationkind(state, get(continuationroles, get(message, "role", ""), Conversation.Continue))
continue_tail!(agent) = continue_tail!(agent, foldl(continuationkind, agent.messages; init=nothing))
continue_tail!(agent, ::Nothing) = :empty
function continue_tail!(agent, ::Type{Conversation.ContinueQueued})
    isempty(agent.state.steering) && isempty(agent.state.followups) && return :assistant_tail
    startturn!(agent)
    Conversation.ContinueQueued
end
function continue_tail!(agent, ::Type{Conversation.Continue})
    startturn!(agent)
    Conversation.Continue
end
continue_selected!(agent, result; kwargs...) = result
continue_selected!(agent, constructor::Type{<:Union{Conversation.Continue, Conversation.ContinueQueued}}; kwargs...) = continue_run!(agent, agent.history, constructor; kwargs...)
function continue_run!(agent, history, constructor; on_event, on_agent_event, parameters, tool_execution)
    messages = Dict{String, Any}[]
    callback = EventSink(ReentrantLock(), on_agent_event)
    run = (; agent, on_event, callback, parameters, tool_execution, messages, constructor)
    try
        precompact!(agent, callback)
        syncresult = sync!(agent)
        continue_synced!(run, history, syncresult)
    finally
        try
            continue_finish!(agent, history)
            emit(callback, (; type=:agent_end, messages=deepcopy(messages)))
        finally
            finish!(agent)
        end
    end
end
continue_synced!(run, history, rejected::History.Rejected) = rejected
function continue_synced!(run, history, ::Nothing)
    result, _ = transition!(revision -> run.constructor(revision), run.agent)
    continue_prepared!(run, history, result)
end
continue_prepared!(run, history, result) = result
function continue_prepared!(run, history, result::Kernel.Applied)
    emit(run.callback, (; type=:agent_start))
    emit(run.callback, (; type=:turn_start))
    continue_advance!(run, history)
end
function continue_advance!(run, ::Nothing)
    direct_cancel!(run, turnstate(run.agent))
    next, added = transition!(revision -> Conversation.Advance(revision), run.agent)
    present!(run.agent, added, run.messages, run.callback)
    direct_ready!(run, next, turnstate(run.agent))
end
continue_advance!(run, ::History.Store) = recorded_cancel!(run, run.agent.fault)
function continue_finish!(agent, ::Nothing)
    interrupt!(agent, agent.state.phase)
    sync!(agent)
end
continue_finish!(agent, ::History.Store) = interrupted!(agent)
