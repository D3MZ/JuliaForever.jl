module Extensions

using ..JuliaForever: Tool, ToolResult, name, Terminate

"A value plugin. Packages can instead define `tools` and `hooks` for their own types."
struct Plugin{T, H}
    tools::T
    hooks::H
end

Plugin(; tools=(), hooks=()) = Plugin(tools, hooks)
tools(plugin::Plugin) = plugin.tools
hooks(plugin::Plugin) = plugin.hooks
tools(plugin) = ()
hooks(plugin) = ()

struct Hook
    plugin::Symbol
    event::Symbol
    handler::Any
end

struct Entry
    id::Symbol
    tools::Vector{Tool}
    hooks::Vector{Hook}
end

struct Registry
    lock::ReentrantLock
    entries::Vector{Entry}
end

Registry() = Registry(ReentrantLock(), Entry[])

struct Rejected
    reason::Symbol
    name::String
end

"Register a plugin atomically, rejecting duplicate plugin IDs and tool names."
function register!(registry::Registry, id::Symbol, plugin)
    candidates = Tool[tool for tool in tools(plugin)]
    handlers = Hook[Hook(id, first(hook), last(hook)) for hook in hooks(plugin)]
    lock(registry.lock) do
        any(entry -> entry.id == id, registry.entries) && return Rejected(:duplicate_plugin, string(id))
        names = Set{String}(name(tool) for entry in registry.entries for tool in entry.tools)
        for tool in candidates
            key = String(name(tool))
            key in names && return Rejected(:duplicate_tool, key)
            push!(names, key)
        end
        push!(registry.entries, Entry(id, candidates, handlers))
        true
    end
end

"Remove an ID from future snapshots. Existing snapshots remain unchanged."
function remove!(registry::Registry, id::Symbol)
    lock(registry.lock) do
        remove!(registry.entries, findfirst(entry -> entry.id == id, registry.entries))
    end
end

remove!(entries::Vector{Entry}, ::Nothing) = false

function remove!(entries::Vector{Entry}, index::Int)
    deleteat!(entries, index)
    true
end

struct Snapshot
    tools::Tuple
    hooks::Tuple
end

"Capture registration order for an agent and its listener."
function snapshot(registry::Registry)
    lock(registry.lock) do
        alltools = Tool[]
        allhooks = Hook[]
        for entry in registry.entries
            append!(alltools, entry.tools)
            append!(allhooks, entry.hooks)
        end
        Snapshot(Tuple(alltools), Tuple(allhooks))
    end
end

tools(snapshot::Snapshot) = Tool[snapshot.tools...]

struct Failure
    plugin::Symbol
    event::Symbol
    exception::Any
end

struct Listener{F}
    lock::ReentrantLock
    hooks::Tuple
    events::Dict{Symbol, Tuple}
    errors::Vector{Failure}
    on_event::F
end

function hookevents(hooks)
    events = Dict{Symbol, Tuple}()
    for hook in hooks
        events[hook.event] = (get(events, hook.event, ())..., hook)
    end
    events
end
Listener(lock, hooks, errors, on_event) = Listener(lock, hooks, hookevents(hooks), errors, on_event)

"Create a synchronous lifecycle observer and optional host callback."
listen(snapshot::Snapshot; on_event=nothing) = Listener(ReentrantLock(), snapshot.hooks, Failure[], on_event)

deliver(::Nothing, event) = nothing
deliver(callback, event) = callback(event)

function (listener::Listener)(event)
    lock(listener.lock) do
        for hook in get(listener.events, event.type, ())
            try
                hook.handler(deepcopy(event))
            catch exception
                push!(listener.errors, Failure(hook.plugin, event.type, exception))
            end
        end
        deliver(listener.on_event, event)
    end
    nothing
end

"Return the hook failures captured by a listener."
failures(listener::Listener) = lock(() -> copy(listener.errors), listener.lock)

struct Proceed{T<:ToolResult}
    result::T
end

"A tool-call hook response that blocks execution."
struct Block{T}
    reason::String
    termination::T
end
const terminations = Dict(false => identity, true => Terminate)
Block(reason="Tool execution was blocked"; terminate=false) = Block(String(reason), terminations[terminate])


end

Agent(provider, snapshot::Extensions.Snapshot; history=nothing) = Agent(provider, Extensions.tools(snapshot); history)
Agent(provider, snapshot::Extensions.Snapshot, messages; history=nothing) = Agent(provider, Dict{String, Tool}(name(tool) => tool for tool in Extensions.tools(snapshot)), messages; history)
Agent(provider, snapshot::Extensions.Snapshot, messages::Vector{Conversation.Message}; history=nothing) = Agent(provider, Dict{String, Tool}(name(tool) => tool for tool in Extensions.tools(snapshot)), messages; history)

"""Chain `:tool_result` hooks on a listener. Return a `ToolResult` to replace the current result, or `nothing` to leave it unchanged. Hook failures are recorded and later hooks still run. Pass this listener as `on_agent_event` to enable interception."""
function interceptresult(listener::Extensions.Listener, call, args, result::ToolResult)
    lock(listener.lock) do
        current = result
        for hook in get(listener.events, :tool_result, ())
            event = (; type=:tool_result, tool_call_id=call["id"], tool_name=callinfo(call).name, args, result=current)
            try
                current = resultvalue(current, hook.handler(deepcopy(event)))
            catch exception
                push!(listener.errors, Extensions.Failure(hook.plugin, :tool_result, exception))
            end
        end
        discovery(result, current)
    end
end

discovery(original::ToolResult, result::ToolResult) = result
discovery(original::ToolLoaded, result::ToolLoaded) = result
discovery(original::ToolLoaded, result::ToolResult) = ToolDiscovery(result, loaded(original))
discovery(original::ToolLoaded, result::Terminate) = Terminate(ToolDiscovery(result.result, loaded(original)))

resultvalue(current::ToolResult, result::Extensions.Proceed) = result.result
resultvalue(current::ToolResult, ::Nothing) = current
resultvalue(current::ToolResult, result::ToolResult) = result
resultvalue(current::Terminate, result::ToolResult) = Terminate(result)
resultvalue(current::Terminate, result::Terminate) = result

function interceptcall(listener::Extensions.Listener, call, input)
    lock(listener.lock) do
        event = (; type=:tool_call, tool_call_id=call["id"], tool_name=callinfo(call).name, input)
        callhooks(get(listener.events, :tool_call, ()), event)
    end
end
callhooks(::Tuple{}, event) = nothing
callhooks(hooks::Tuple, event) = callhook(first(hooks), Base.tail(hooks), event)
callhook(hook, hooks, event) = nextcall(hook.handler(event), hooks, event)
nextcall(block::Extensions.Block, hooks, event) = block
nextcall(value, hooks, event) = callhooks(hooks, event)
prepare(tool::Tool, input, block::Extensions.Block) = block.termination(ToolFailure(isempty(block.reason) ? "Tool execution was blocked" : block.reason))

abstract type ContextRole end
struct ContextSystem <: ContextRole end
struct ContextBash <: ContextRole end
struct ContextOther <: ContextRole end
const contextroles = Dict("system" => ContextSystem(), "bashExecution" => ContextBash())
contextrole(message) = get(contextroles, get(message, "role", ""), ContextOther())
contexthead(messages) = isempty(messages) ? ContextOther() : contextrole(first(messages))
contextwarning!(listener, hook, before, after) = nothing
function contextwarning!(listener, hook, ::ContextSystem, after::Union{ContextOther, ContextBash})
    push!(listener.errors, Extensions.Failure(hook.plugin, :context_with_system, ErrorException("Handler removed the leading system message; the request has no prompt or initial tool declarations. Keep it at index 0 or replace a dropped prefix with getCurrentSystemMessage().")))
end

contextmessages(callback, messages) = messages
contextmessages(sink::EventSink, messages) = lock(() -> contextmessages(sink.callback, messages), sink.lock)

function contextmessages(listener::Extensions.Listener, messages)
    lock(listener.lock) do
        current = deepcopy(messages)
        for hook in get(listener.events, :context, ())
            visible = filter(message -> contextrole(message) != ContextSystem(), current)
            snapshot = copy(visible)
            try
                result = hook.handler((; type=:context, messages=visible))
                returned = contextresult(result, visible, snapshot)
                current = restorecontext(current, snapshot, returned)
            catch exception
                push!(listener.errors, Extensions.Failure(hook.plugin, :context, exception))
            end
        end
        for hook in get(listener.events, :context_with_system, ())
            leading = contexthead(current)
            try
                result = hook.handler((; type=:context_with_system, messages=current))
                current = contextresult(result, current)
                contextwarning!(listener, hook, leading, contexthead(current))
            catch exception
                push!(listener.errors, Extensions.Failure(hook.plugin, :context_with_system, exception))
            end
        end
        current
    end
end

contextresult(::Nothing, current) = current
contextresult(result, current) = current
contextresult(result::NamedTuple, current) = contextreplacement(get(result, :messages, nothing), current)
contextresult(result::AbstractDict, current) = contextreplacement(get(result, :messages, get(result, "messages", nothing)), current)
contextresult(::Nothing, visible, snapshot) = visible
contextresult(result, visible, snapshot) = visible
contextresult(result::NamedTuple, visible, snapshot) = contextreplacement(get(result, :messages, nothing), visible)
contextresult(result::AbstractDict, visible, snapshot) = contextreplacement(get(result, :messages, get(result, "messages", nothing)), visible)
contextreplacement(::Nothing, current) = current
contextreplacement(messages, current) = messages
samemessages(left, right) = length(left) == length(right) && all(a === b for (a, b) in zip(left, right))
function restorecontext(current, visible, returned)
    samemessages(returned, visible) && return current
    head = currentsystem(current)
    restorecontext(head, returned)
end
restorecontext(::Nothing, returned) = returned
restorecontext(head, returned) = [head; returned]

systemtext(content::AbstractString) = content
systemtext(content) = join(Iterators.flatten(contextblock(block) for block in content), "\n")
contextblock(block) = get(contextblocks, get(block, "type", ""), contextother)(block)
contextother(block) = ()
contexttext(block) = (block["text"],)
const contextblocks = Dict("text" => contexttext)
function currentsystem(messages)
    systems = filter(message -> contextrole(message) == ContextSystem(), messages)
    isempty(systems) && return nothing
    texts = String[]
    sections = OrderedDict{String, Any}()
    tools = OrderedDict{String, Any}()
    for message in systems
        text = systemtext(get(message, "content", ""))
        isempty(text) || push!(texts, text)
        for (key, value) in get(message, "sections", Dict())
            updatesection!(sections, key, value)
        end
        for tool in get(message, "toolsRemoved", [])
            pop!(tools, tool["name"], nothing)
        end
        for tool in get(message, "toolsAdded", [])
            name = tool["name"]
            tools[name] = tool
        end
    end
    head = Dict{String, Any}("role" => "system", "content" => join(texts, "\n\n"), "timestamp" => get(first(systems), "timestamp", 0))
    isempty(sections) || (head["sections"] = sections)
    isempty(tools) || (head["toolsAdded"] = collect(values(tools)))
    head
end
updatesection!(sections, key, ::Nothing) = pop!(sections, key, nothing)
updatesection!(sections, key, value) = (sections[key] = value)

projectcontext!(result, message, role) = push!(result, message)
sectiontext(::Nothing) = ()
sectiontext(value) = (value,)
function projectcontext!(result, message, ::ContextBash)
    bash = Conversation.BashMessage(message["command"], message["output"], get(message, "exitCode", nothing), Conversation.bashstatuses[get(message, "cancelled", false)], Conversation.bashextents[get(message, "truncated", false)], get(message, "fullOutputPath", nothing), get(message, "timestamp", 0), Conversation.bashcontext(get(message, "excludeFromContext", nothing)))
    modelmessage!(result, bash)
end

struct RequestView{M, T}
    messages::M
    tools::T
end
struct UnsupportedContextRequest end

contextfailure() = Completion(Dict{String, Any}("role" => "assistant", "content" => nothing), nothing, nothing, Unfinished(), "Unsupported constrained sampling in request-context tool declarations")
contextfailure!(::Nothing, result) = nothing
contextfailure!(on_event, result) = on_event((; type=:incomplete, result))
function contextfailure(agent, on_event)
    result = contextfailure()
    contextfailure!(on_event, result)
    merge(response(result), (; info=responseinfo(agent.provider, round(Int, 1000time()))))
end
response(agent, ::UnsupportedContextRequest, parameters, ::Nothing, on_agent_event) = contextfailure(agent, nothing)
response(agent, ::UnsupportedContextRequest, parameters, on_event, on_agent_event) = contextfailure(agent, on_event)

struct ResponseContextUpdate
    items::Vector{Any}
end

struct AnthropicContextUpdate
    data::Dict{String, Any}
    blocks::Vector{Any}
end
Base.pairs(update::AnthropicContextUpdate) = pairs(update.data)
Base.getindex(update::AnthropicContextUpdate, key) = update.data[key]

struct NativeAnthropicTools
    items::OrderedDict{String, Tool}
end
Base.values(tools::NativeAnthropicTools) = values(tools.items)
Base.isempty(tools::NativeAnthropicTools) = isempty(tools.items)

struct ToolDeclaration <: Tool
    data::Dict{String, Any}
end
struct CatalogDeclaration <: Tool
    data::Dict{String, Any}
end
abstract type ContextStrict end
struct ContextStrictSupported <: ContextStrict end
struct ContextStrictUnsupported <: ContextStrict end
name(tool::Union{ToolDeclaration, CatalogDeclaration}) = tool.data["name"]
description(tool::Union{ToolDeclaration, CatalogDeclaration}) = tool.data["description"]
schema(tool::Union{ToolDeclaration, CatalogDeclaration}) = tool.data["parameters"]

requestview(callback, messages, tools, provider) = RequestView(modelmessages(messages), tools)
requestview(sink::EventSink, messages, tools, provider) = lock(() -> requestview(sink.callback, messages, tools, provider), sink.lock)
function requestview(listener::Extensions.Listener, messages, tools, provider)
    isempty(get(listener.events, :context, ())) && isempty(get(listener.events, :context_with_system, ())) && return RequestView(modelmessages(messages), tools)
    raw = Dict{String, Any}[convert(Dict{String, Any}, message) for message in messages]
    seedtools!(raw, tools)
    transformed = contextmessages(listener, raw)
    projected = Dict{String, Any}[]
    foreach(message -> projectcontext!(projected, message, contextrole(message)), transformed)
    current = currentsystem(projected)
    providerrequest(provider, projected, current, tools)
end

function seedtools!(messages, tools)
    declarations = [definition(tool)["function"] for tool in values(tools)]
    isempty(declarations) && return messages
    seedtools!(messages, declarations, contexthead(messages))
end
function seedtools!(messages, declarations, ::ContextSystem)
    message = first(messages)
    message["toolsAdded"] = [declarations; get(message, "toolsAdded", [])]
    messages
end
function seedtools!(messages, declarations, role)
    pushfirst!(messages, Dict{String, Any}("role" => "system", "content" => "", "timestamp" => 0, "toolsAdded" => declarations))
    messages
end

requesttools(::Nothing, tools) = OrderedDict{String, Tool}()
function requesttools(system, tools)
    result = OrderedDict{String, Tool}()
    for declaration in get(system, "toolsAdded", [])
        key = String(declaration["name"])
        result[key] = requesttool(get(tools, key, nothing), declaration)
    end
    result
end
requesttool(::Nothing, declaration) = ToolDeclaration(Dict{String, Any}(string(key) => deepcopy(value) for (key, value) in pairs(declaration)))
function requesttool(tool::Tool, declaration)
    definition(tool)["function"] == declaration ? tool : requesttool(nothing, declaration)
end

abstract type ToolBaseline end
struct RetainTools <: ToolBaseline end
struct ClearTools <: ToolBaseline end
struct ToolChanges{B<:ToolBaseline}
    baseline::B
    removed::Vector{String}
    added::Vector{ToolDeclaration}
end
toolbaseline(before, after) = RetainTools()
toolbaseline(::ContextSystem, ::Union{ContextOther, ContextBash}) = ClearTools()
declaration(tool::Tool) = ToolDeclaration(Dict{String, Any}(string(key) => deepcopy(value) for (key, value) in pairs(definition(tool)["function"])))
function toolchanges(before, after, messages, baseline)
    previous = collect(keys(before))
    current = collect(keys(after))
    removed = [key for key in previous if !haskey(after, key)]
    for message in messages
        removedtools!(removed, message, after, contextrole(message))
    end
    unique!(removed)
    added = [key for key in current if !haskey(before, key) || definition(before[key]) != definition(after[key])]
    expected = [[key for key in previous if key ∉ removed]; [key for key in added if key ∉ previous]]
    previous, added = orderedchanges(previous, current, removed, added, expected)
    previous, added = baselinechanges(baseline, previous, added, current)
    ToolChanges(baseline, previous, ToolDeclaration[declaration(after[key]) for key in added])
end
removedtools!(removed, message, after, role) = nothing
function removedtools!(removed, message, after, ::ContextSystem)
    for tool in get(message, "toolsRemoved", [])
        key = String(tool["name"])
        haskey(after, key) || push!(removed, key)
    end
    nothing
end
orderedchanges(previous, current, removed, added, expected) = expected == current ? (removed, added) : (unique([removed; previous]), current)
baselinechanges(::RetainTools, removed, added, current) = (removed, added)
baselinechanges(::ClearTools, removed, added, current) = (removed, current)

basetools(tools, ::RetainTools) = OrderedDict{String, Tool}(String(key) => value for (key, value) in pairs(tools))
basetools(tools, ::ClearTools) = OrderedDict{String, Tool}()
function applychanges(tools, changes::ToolChanges)
    result = basetools(tools, changes.baseline)
    foreach(key -> pop!(result, key, nothing), changes.removed)
    for tool in changes.added
        key = name(tool)
        result[key] = requesttool(get(tools, key, nothing), tool.data)
    end
    result
end

providercontext(provider, messages, system) = messages
abstract type ContextSampling end
struct UnconstrainedContext <: ContextSampling end
struct ConstrainedContext <: ContextSampling end
const contextsampling = Dict(false => UnconstrainedContext(), true => ConstrainedContext())
samplingvalue(::Nothing) = UnconstrainedContext()
samplingvalue(value::Bool) = contextsampling[value]
samplingvalue(value) = ConstrainedContext()
samplingcombine(::UnconstrainedContext, next::ContextSampling) = next
samplingcombine(::ConstrainedContext, next::ContextSampling) = ConstrainedContext()
samplingtool(current, tool) = samplingcombine(current, samplingvalue(get(tool, "constrainedSampling", nothing)))
samplingmessage(current, message, role) = current
samplingmessage(current, message, ::ContextSystem) = foldl(samplingtool, get(message, "toolsAdded", []); init=current)
samplingmessage(current, message) = samplingmessage(current, message, contextrole(message))
contextsamplingmode(messages) = foldl(samplingmessage, messages; init=UnconstrainedContext())

providerrequest(provider, messages, system, tools) = contextrequest(provider, messages, system, requesttools(system, tools))
contextrequest(::Nothing, messages, system, tools) = providerprepared(nothing, messages, system, tools)
contextrequest(provider, messages, system, tools) = contextrequest(contextsamplingmode(messages), provider, messages, system, tools)
contextrequest(::UnconstrainedContext, provider, messages, system, tools) = providerprepared(provider, messages, system, tools)
contextrequest(::ConstrainedContext, provider, messages, system, tools) = UnsupportedContextRequest()
providerprepared(provider, messages, system, tools) = RequestView(providercontext(provider, messages, system), tools)
function collapsedcontext(messages, system)
    result = Dict{String, Any}[]
    appendsystem!(result, system)
    append!(result, filter(message -> contextrole(message) != ContextSystem(), messages))
end
appendsystem!(result, ::Nothing) = result
function appendsystem!(result, system)
    parts = [systemtext(get(system, "content", "")); collect(Iterators.flatten(sectiontext(value) for value in values(get(system, "sections", Dict()))))]
    text = join(filter(!isempty, parts), "\n\n")
    isempty(text) || push!(result, Dict{String, Any}("role" => "system", "content" => text))
    result
end
