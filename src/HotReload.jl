module HotReload

# Feature generations are isolated modules. A request retains the generation
# that supplied its tool schemas, while later requests use the new generation.
struct Generation
    source::Module
    schemas::Vector{Any}
    names::Set{String}
end

mutable struct Manager
    path::String
    host::Module
    lock::ReentrantLock
    generation::Union{Nothing,Generation}
    state::Dict{Symbol,Any}
    notice::String
    disabled::Set{Symbol}
    stopped::Threads.Atomic{Bool}
    task::Union{Nothing,Task}
end

const CURRENT = Ref{Union{Nothing,Manager}}(nothing)

function candidate(manager::Manager, source::String)
    mod = Module(gensym(:JuliaForeverFeature))
    Core.eval(mod, :(const App = $(QuoteNode(manager.host))))
    Base.include_string(mod, source, manager.path)
    for name in (:tool_schemas, :run_tool, :on_key!, :on_frame!, :footer, :shutdown!)
        Base.invokelatest(isdefined, mod, name) || error("Live feature is missing $name")
        Base.invokelatest(getfield, mod, name) isa Function || error("Live feature $name must be a function")
    end
    raw = Base.invokelatest(Base.invokelatest(getfield, mod, :tool_schemas))
    raw isa AbstractVector || error("tool_schemas must return a vector")
    schemas, names = Any[], Set{String}()
    for schema in raw
        schema isa AbstractDict || error("Each live tool schema must be an object")
        get(schema, "type", "") == "function" || error("Live tools must be function schemas")
        name = get(schema, "name", nothing)
        name isa AbstractString && !isempty(name) || error("Live tools need a name")
        name in ("list", "search", "read", "write", "edit", "command") && error("Live tool conflicts with a built-in tool: $name")
        name in names && error("Duplicate live tool: $name")
        push!(names, String(name))
        push!(schemas, schema)
    end
    Generation(mod, schemas, names)
end

function set_notice!(manager::Manager, message::String)
    lock(manager.lock) do
        manager.notice = message
    end
end

function reload!(manager::Manager, source::String; announce::Bool=true)
    generation = candidate(manager, source)
    lock(manager.lock) do
        manager.generation = generation
        empty!(manager.disabled)
        announce && (manager.notice = "Live features reloaded.")
    end
    generation
end

function start!(host::Module, path::String=joinpath(@__DIR__, "LiveFeatures.jl"))
    CURRENT[] === nothing || return CURRENT[]
    manager = Manager(path, host, ReentrantLock(), nothing, Dict{Symbol,Any}(), "",
                      Set{Symbol}(), Threads.Atomic{Bool}(false), nothing)
    CURRENT[] = manager
    source = try
        read(path, String)
    catch error
        set_notice!(manager, "Live features unavailable: " * sprint(showerror, error))
        ""
    end
    if !isempty(source)
        try
            reload!(manager, source; announce=false)
        catch error
            set_notice!(manager, "Live reload failed: " * sprint(showerror, error))
        end
    end
    manager.task = Threads.@spawn begin
        seen = source
        pending = source
        while !manager.stopped[]
            sleep(0.3)
            manager.stopped[] && break
            content = try read(manager.path, String) catch; continue end
            if content != pending
                pending = content
                continue
            end
            content == seen && continue
            seen = content
            try
                reload!(manager, content)
            catch error
                set_notice!(manager, "Live reload failed; previous version retained: " * sprint(showerror, error))
            end
        end
    end
    manager
end

function snapshot()
    manager = CURRENT[]
    manager === nothing && return nothing
    lock(manager.lock) do
        manager.generation
    end
end

tool_schemas(generation::Nothing) = Any[]
tool_schemas(generation::Generation) = generation.schemas
has_tool(::Nothing, name::AbstractString) = false
has_tool(generation::Generation, name::AbstractString) = name in generation.names

function run_tool(generation::Generation, session, name, args)
    manager = CURRENT[]
    manager === nothing && error("Live features are not running")
    callback = Base.invokelatest(getfield, generation.source, :run_tool)
    Base.invokelatest(callback, session, name, args, manager.state)
end

function invoke_ui(name::Symbol, fallback, args...)
    manager = CURRENT[]
    manager === nothing && return fallback
    generation = lock(manager.lock) do
        name in manager.disabled ? nothing : manager.generation
    end
    generation === nothing && return fallback
    try
        callback = Base.invokelatest(getfield, generation.source, name)
        Base.invokelatest(callback, args..., manager.state)
    catch error
        lock(manager.lock) do
            push!(manager.disabled, name)
            manager.notice = "Live feature $name failed: " * sprint(showerror, error)
        end
        fallback
    end
end

on_key!(menu, event) = invoke_ui(:on_key!, false, menu, event) === true
on_frame!(menu) = invoke_ui(:on_frame!, nothing, menu)
footer(menu) = invoke_ui(:footer, "", menu)

function take_notice!()
    manager = CURRENT[]
    manager === nothing && return ""
    lock(manager.lock) do
        message = manager.notice
        manager.notice = ""
        message
    end
end

function stop!()
    manager = CURRENT[]
    manager === nothing && return
    manager.stopped[] = true
    manager.task === nothing || wait(manager.task)
    invoke_ui(:shutdown!, nothing)
    CURRENT[] = nothing
end

end
