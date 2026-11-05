module HotReload

struct Generation
    sources::Vector{Pair{String,Module}}
    schemas::Vector{Any}
    names::Dict{String,Module}
end

mutable struct Manager
    path::String
    host::Module
    lock::ReentrantLock
    generation::Union{Nothing,Generation}
    states::Dict{String,Dict{Symbol,Any}}
    notice::String
    disabled::Set{Tuple{String,Symbol}}
    stopped::Threads.Atomic{Bool}
    task::Union{Nothing,Task}
end

const CURRENT = Ref{Union{Nothing,Manager}}(nothing)

function sources_at(path::String)
    paths = if isempty(path)
        String[]
    elseif isdir(path)
        sort!([joinpath(path, name) for name in readdir(path)
               if endswith(name, ".jl") && isfile(joinpath(path, name))])
    elseif isfile(path)
        [path]
    else
        String[]
    end
    Pair{String,String}[p => read(p, String) for p in paths]
end

function candidate(manager::Manager, sources::Vector{Pair{String,String}})
    modules, schemas, names = Pair{String,Module}[], Any[], Dict{String,Module}()
    for (path, source) in sources
        mod = Module(gensym(:JuliaForeverFeature))
        Core.eval(mod, :(const App = $(QuoteNode(manager.host))))
        Base.include_string(mod, source, path)
        for name in (:tool_schemas, :run_tool, :on_key!, :on_frame!, :footer, :shutdown!)
            Base.invokelatest(isdefined, mod, name) || error("$(basename(path)) is missing $name")
            Base.invokelatest(getfield, mod, name) isa Function || error("$(basename(path)): $name must be a function")
        end
        raw = Base.invokelatest(Base.invokelatest(getfield, mod, :tool_schemas))
        raw isa AbstractVector || error("$(basename(path)): tool_schemas must return a vector")
        for schema in raw
            schema isa AbstractDict || error("Each live tool schema must be an object")
            get(schema, "type", "") == "function" || error("Live tools must be function schemas")
            name = get(schema, "name", nothing)
            name isa AbstractString && !isempty(name) || error("Live tools need a name")
            name in ("list", "search", "read", "write", "edit", "command") && error("Live tool conflicts with a built-in tool: $name")
            haskey(names, name) && error("Duplicate live tool: $name")
            names[String(name)] = mod
            push!(schemas, schema)
        end
        push!(modules, path => mod)
    end
    Generation(modules, schemas, names)
end

function set_notice!(manager::Manager, message::String)
    lock(manager.lock) do
        manager.notice = message
    end
end

function reload!(manager::Manager, sources::Vector{Pair{String,String}}; announce::Bool=true)
    generation = candidate(manager, sources)
    removed = Pair{Module,Dict{Symbol,Any}}[]
    lock(manager.lock) do
        old = manager.generation
        newpaths = Set(first.(generation.sources))
        if old !== nothing
            for (path, mod) in old.sources
                if !(path in newpaths) && haskey(manager.states, path)
                    push!(removed, mod => pop!(manager.states, path))
                end
            end
        end
        for (path, _) in generation.sources
            get!(manager.states, path, Dict{Symbol,Any}())
        end
        manager.generation = generation
        empty!(manager.disabled)
        announce && (manager.notice = "Live features reloaded.")
    end
    for (mod, state) in removed
        try Base.invokelatest(getfield(mod, :shutdown!), state) catch end
    end
    generation
end

function start!(host::Module, path::String)
    CURRENT[] === nothing || return CURRENT[]
    manager = Manager(path, host, ReentrantLock(), nothing, Dict{String,Dict{Symbol,Any}}(), "",
                      Set{Tuple{String,Symbol}}(), Threads.Atomic{Bool}(false), nothing)
    CURRENT[] = manager
    sources = try
        sources_at(path)
    catch error
        set_notice!(manager, "Live features unavailable: " * sprint(showerror, error))
        Pair{String,String}[]
    end
    try
        reload!(manager, sources; announce=false)
    catch error
        set_notice!(manager, "Live reload failed: " * sprint(showerror, error))
    end
    manager.task = Threads.@spawn begin
        seen, pending = sources, sources
        while !manager.stopped[]
            sleep(0.3)
            manager.stopped[] && break
            content = try sources_at(manager.path) catch; continue end
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

tool_schemas(::Nothing) = Any[]
tool_schemas(generation::Generation) = generation.schemas
has_tool(::Nothing, name::AbstractString) = false
has_tool(generation::Generation, name::AbstractString) = haskey(generation.names, name)

function run_tool(generation::Generation, session, name, args)
    manager = CURRENT[]
    manager === nothing && error("Live features are not running")
    mod = generation.names[name]
    path = first(first(filter(pair -> last(pair) === mod, generation.sources)))
    state = lock(manager.lock) do
        get!(manager.states, path, Dict{Symbol,Any}())
    end
    Base.invokelatest(getfield(mod, :run_tool), session, name, args, state)
end

function invoke_ui(name::Symbol, fallback, args...)
    manager = CURRENT[]
    manager === nothing && return fallback
    generation = snapshot()
    generation === nothing && return fallback
    results = Any[]
    for (path, mod) in generation.sources
        state = lock(manager.lock) do
            (path, name) in manager.disabled ? nothing : get!(manager.states, path, Dict{Symbol,Any}())
        end
        state === nothing && continue
        try
            value = Base.invokelatest(getfield(mod, name), args..., state)
            name == :on_key! && value === true && return true
            name == :footer && value isa AbstractString && !isempty(value) && push!(results, String(value))
        catch error
            lock(manager.lock) do
                push!(manager.disabled, (path, name))
                manager.notice = "Live feature $(basename(path)) $name failed: " * sprint(showerror, error)
            end
        end
    end
    name == :footer && !isempty(results) ? join(results, "  ") : fallback
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
