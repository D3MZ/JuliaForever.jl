module Extensions

using ..JuliaForever: Tool, name

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
        index = findfirst(entry -> entry.id == id, registry.entries)
        isnothing(index) && return false
        deleteat!(registry.entries, index)
        true
    end
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
    errors::Vector{Failure}
    on_event::F
end

"Create a synchronous lifecycle observer and optional host callback."
listen(snapshot::Snapshot; on_event=nothing) = Listener(ReentrantLock(), snapshot.hooks, Failure[], on_event)

function (listener::Listener)(event)
    lock(listener.lock) do
        for hook in listener.hooks
            hook.event == event.type || continue
            try
                hook.handler(deepcopy(event))
            catch exception
                push!(listener.errors, Failure(hook.plugin, event.type, exception))
            end
        end
        isnothing(listener.on_event) || listener.on_event(event)
    end
    nothing
end

"Return the hook failures captured by a listener."
failures(listener::Listener) = lock(() -> copy(listener.errors), listener.lock)

end

Agent(provider, snapshot::Extensions.Snapshot; history=nothing) = Agent(provider, Extensions.tools(snapshot); history)
Agent(provider, snapshot::Extensions.Snapshot, messages; history=nothing) = Agent(provider, Dict{String, Tool}(name(tool) => tool for tool in Extensions.tools(snapshot)), messages; history)
