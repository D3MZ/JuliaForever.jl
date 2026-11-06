module BuildCore

using JSON
import ..ChatGPTAuth
import ..HotReload
import ..NativeAgent
import ..Skills

const ROOT = normpath(joinpath(@__DIR__, ".."))
bin_dir() = abspath(expanduser(get(ENV, "JULIAFOREVER_BIN", joinpath(homedir(), ".local", "bin"))))

mutable struct FeatureJob
    state::Symbol
    started::Float64
    dir::String
    control::NativeAgent.TurnControl
    task::Union{Nothing,Task}
    error::String
    tools::Vector{String}
end

mutable struct BuildSession
    model::String
    window::Int
    skills::Vector{Skills.Skill}
    skill_errors::Vector{String}
    scratch::String
    lock::ReentrantLock
    jobs::Dict{String,FeatureJob}
    tasks::Vector{Task}
    durations::Dict{String,Vector{Float64}}
    final_state::Symbol
    final_error::String
    final_token::Int
    build_done::Bool
    alias_done::Bool
    final_started::Float64
    install_dir::String
end

function load_durations()
    data = ChatGPTAuth.read_json("build-durations.json")
    data === nothing && return Dict{String,Vector{Float64}}()
    try
        Dict(String(k) => Float64[x for x in v if x isa Real && isfinite(x) && x > 0]
             for (k, v) in data if v isa AbstractVector)
    catch
        Dict{String,Vector{Float64}}()
    end
end

function BuildSession(model::String, window::Int)
    catalog = Skills.discover()
    scratch = mktempdir(; prefix="juliaforever-build-")
    chmod(scratch, 0o700)
    BuildSession(model, window, catalog.skills, catalog.errors, scratch, ReentrantLock(), Dict{String,FeatureJob}(), Task[],
                 load_durations(), :idle, "", 0, false, false, 0.0, "")
end

function record_duration!(builder::BuildSession, key::String, seconds::Real)
    isfinite(seconds) && seconds > 0 || return
    values = get!(builder.durations, key, Float64[])
    push!(values, Float64(seconds))
    length(values) > 20 && deleteat!(values, 1:(length(values) - 20))
    try ChatGPTAuth.save_json("build-durations.json", builder.durations) catch end
end

function refresh_skills!(builder::BuildSession, catalog=Skills.discover())
    lock(builder.lock) do
        present = Set(skill.id for skill in catalog.skills)
        append!(catalog.skills, [skill for skill in builder.skills
                                if haskey(builder.jobs, skill.id) && !(skill.id in present)])
        sort!(catalog.skills; by=s -> (s.order, lowercase(s.name), s.id))
        changed = [(s.path, s.source) for s in builder.skills] != [(s.path, s.source) for s in catalog.skills] ||
                  builder.skill_errors != catalog.errors
        builder.skills, builder.skill_errors = catalog.skills, catalog.errors
        changed
    end
end

function skill(builder::BuildSession, id::String)
    lock(builder.lock) do
        i = findfirst(s -> s.id == id, builder.skills)
        i === nothing && error("Unknown skill: $id")
        builder.skills[i]
    end
end

const HOST = """
Host interface available through App (the JuliaForever module):
- App.Tachikoma: text(input), clear!(input), key_press, key_release, raw_capture_enabled(),
  last_event_raw(), _run_validator!(input).
- menu fields: prompt (TextInput), prompt_editor, session (has .cwd and .model), busy (Bool),
  notice (String), transcript (vector of App.ChatEntry), scroll (Int).
- App.queue_prompt!(menu, :steer) or App.queue_prompt!(menu, :queue) delivers the composer text.
- App.save_edit!(menu.prompt_editor, menu.prompt, action) records an undo step before an edit.
- App.ChatEntry(kind=:notice or :error, text=...) appends a visible chat line.
- App.ChatGPTAuth.access_token() returns a current OAuth bearer token from the app sign-in and
  refreshes it when needed. App.ChatGPTAuth.ensure_dir() is the private config directory; create
  directories with mode=0o700 and files with mode=0o600. App.ChatGPTAuth.Base64 has
  base64encode(bytes) and base64decode(text).
- App.NativeAgent.HTTP is the HTTP package; App.JSON is JSON.
- Stream server-sent events by passing sse_callback=callback to HTTP.request; the callback receives
  an event whose .data is a String. Do not call HTTP.sse_callback or pass response_stream. Use
  status_exception=false, redirect=false, retry=false, proxy=HTTP.ProxyConfig(), and wrap requests in
  Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) so headers are never logged. Use
  read_idle_timeout, not the deprecated readtimeout. Max SSE line size defaults to 1 MiB; when a
  response carries image data, pass max_sse_line_bytes=33554432 and max_sse_event_bytes=67108864.
- Tool results are strings shown to the model. Return a short success message, or a string starting
  with "Error: " that never contains tokens, account ids, headers, data URLs, or raw request bodies.
- tool_schemas() returns a Vector of flat tool records: Dict("type" => "function", "name" =>
  name, "description" => text, "strict" => true, "parameters" => the JSON object schema). Do not
  nest the record under a "function" key, and do not omit "name" or the top-level "strict".
"""

function build_prompt(selected::Skills.Skill, available::Vector{Skills.Skill})
    catalog = join(["- $(s.id): $(replace(s.description, r"\s+" => " ")) ($(s.path))"
                    for s in available if s.id != selected.id], '\n')
    "Build the $(selected.name) feature for JuliaForever in this isolated working directory. " *
    "Follow the selected skill below; its SKILL.md and supporting files are also in the skill directory. " *
    "Write the complete idiomatic Julia implementation yourself to feature.jl using your local tools; " *
    "no tests, documentation, or code comments. " *
    "The file is included into a fresh module with a constant App referring to JuliaForever. " *
    "It must define seven top-level functions: tool_schemas(), run_tool(session,name,args,state), " *
    "on_key!(menu,event,state), on_frame!(menu,state), footer(menu,state), shutdown!(state), " *
    "and on_reload!(state), including no-ops the skill does not otherwise use. " *
    "Hooks may use App, Base, and packages accessible through App. state is a persistent " *
    "Dict{Symbol,Any} unique to this feature that survives reloads; only Base and host values " *
    "belong in it. on_reload! runs on the retiring module before changed code becomes active: " *
    "release only version-owned resources and preserve compatible ongoing work. shutdown! stops " *
    "all work when a feature is removed or the harness exits. Without on_reload!, replacement calls " *
    "the old shutdown! for safety. Return false from unhandled on_key! and an empty string from " *
    "footer when no footer is needed. A feature file is self-contained: helper files are not " *
    "installed. Do not edit files outside this working directory. Use the selected skill and its " *
    "supporting files. Other discovered skills are listed by name, description and SKILL.md path; " *
    "read any that are relevant, including their referenced files. Avoid unrelated discovery or " *
    "large tool output.\n\n" * HOST * "\nSelected skill:\n" * selected.instructions *
    "\n\nOther discovered skills:\n" * (isempty(catalog) ? "(none)" : catalog)
end

function check_feature(selected::Skills.Skill, generation)
    expected = selected.tools
    expected === nothing || Set(keys(generation.names)) == Set(first.(expected)) ||
        error("The feature returned the wrong tool schemas.")
    expected_by_name = expected === nothing ? nothing : Dict(expected)
    for schema in generation.schemas
        name = schema["name"]
        get(schema, "strict", false) === true || error("The $name schema must be strict.")
        parameters = get(schema, "parameters", nothing)
        parameters isa AbstractDict && get(parameters, "type", "") == "object" ||
            error("The $name schema must have object parameters.")
        properties = get(parameters, "properties", nothing)
        properties isa AbstractDict || error("The $name schema has no object parameters.")
        required = get(parameters, "required", nothing)
        required isa AbstractVector && all(p -> p isa AbstractString, required) &&
            allunique(required) && Set(required) == Set(keys(properties)) ||
            error("The $name schema has the wrong required parameters.")
        get(parameters, "additionalProperties", nothing) === false ||
            error("The $name schema must reject additional properties.")
        if expected_by_name !== nothing
            Set(keys(properties)) == Set(expected_by_name[name]) ||
                error("The $name schema has the wrong properties.")
        end
    end
    generation
end

function start_feature!(builder::BuildSession, id::String)
    selected = skill(builder, id)
    available = lock(builder.lock) do
        copy(builder.skills)
    end
    job = lock(builder.lock) do
        haskey(builder.jobs, id) && return nothing
        dir = mktempdir(builder.scratch; prefix=id * "-")
        j = FeatureJob(:running, time(), dir, NativeAgent.TurnControl(), nothing, "", String[])
        builder.jobs[id] = j
        j
    end
    job === nothing && return
    task = Threads.@spawn begin
        try
            skill_dir = joinpath(job.dir, "skill")
            cp(dirname(selected.path), skill_dir)
            write(joinpath(skill_dir, "SKILL.md"), selected.source)
            session = NativeAgent.Session(builder.model, builder.window, job.dir; remember=false)
            NativeAgent.run_turn!(session, build_prompt(selected, available), (kind, value) -> nothing;
                                  control=job.control, live=false)
            job.control.cancelled[] && throw(NativeAgent.Cancelled())
            path = joinpath(job.dir, "feature.jl")
            isfile(path) || error("The builder did not write feature.jl.")
            source = read(path, String)
            isempty(strip(source)) && error("The builder returned an empty feature.")
            manager = HotReload.CURRENT[]
            manager === nothing && error("Live feature manager is unavailable.")
            generation = HotReload.candidate(manager, Pair{String,String}[path => source])
            check_feature(selected, generation)
            lock(builder.lock) do
                if get(builder.jobs, id, nothing) === job && !job.control.cancelled[]
                    job.tools = collect(keys(generation.names))
                    job.state = :done
                    record_duration!(builder, id, time() - job.started)
                end
            end
        catch error
            lock(builder.lock) do
                if get(builder.jobs, id, nothing) === job && !job.control.cancelled[]
                    job.state = :failed
                    job.error = error isa NativeAgent.ProviderError || error isa ChatGPTAuth.LoginError ?
                                error.message : sprint(showerror, error)
                end
            end
        finally
            job.control.cancelled[] && try rm(job.dir; recursive=true, force=true) catch end
        end
    end
    lock(builder.lock) do
        job.task = task
        push!(builder.tasks, task)
    end
    nothing
end

function remove_feature!(builder::BuildSession, id::String)
    job = lock(builder.lock) do
        pop!(builder.jobs, id, nothing)
    end
    job === nothing && return
    Threads.@spawn begin
        NativeAgent.cancel!(job.control)
        job.task === nothing || try wait(job.task) catch end
        try rm(job.dir; recursive=true, force=true) catch end
    end
    nothing
end

function snapshot(builder::BuildSession)
    lock(builder.lock) do
        jobs = Dict(id => (state=j.state, error=j.error, tools=copy(j.tools)) for (id, j) in builder.jobs)
        (jobs=jobs, state=builder.final_state, error=builder.final_error,
         build_done=builder.build_done, alias_done=builder.alias_done,
         install_dir=builder.install_dir)
    end
end

function estimate(builder::BuildSession)
    lock(builder.lock) do
        remaining = Float64[]
        for (id, job) in builder.jobs
            job.state == :running || continue
            durations = get(builder.durations, id, Float64[])
            isempty(durations) && return nothing
            push!(remaining, max(0.0, sum(durations) / length(durations) - (time() - job.started)))
        end
        total = isempty(remaining) ? 0.0 : maximum(remaining)
        for key in ("build", "alias")
            done = key == "build" ? builder.build_done : builder.alias_done
            done && continue
            durations = get(builder.durations, key, Float64[])
            isempty(durations) && return nothing
            total += sum(durations) / length(durations)
        end
        total
    end
end

function validate_name(name::String)
    occursin(r"^[A-Za-z][A-Za-z0-9_-]{0,63}$", name) ||
        error("Use 1–64 letters, numbers, hyphens or underscores; start with a letter.")
    name
end

function check_install(name::String)
    Sys.isunix() || error("Named commands currently require a POSIX environment.")
    validate_name(name)
    bin = bin_dir()
    any(p -> abspath(expanduser(isempty(p) ? "." : p)) == bin, split(get(ENV, "PATH", ""), ':')) ||
        error("Add $bin to PATH and restart your shell, then retry.")
    Sys.which(name) === nothing || error("Command '$name' already exists; choose another name.")
    target = joinpath(bin, name)
    (ispath(target) || islink(target)) && error("Command '$name' already exists; choose another name.")
    dest = joinpath(ChatGPTAuth.config_dir(), "harnesses", name)
    (ispath(dest) || islink(dest)) && error("Harness '$name' already exists; choose another name.")
    dest
end

shellquote(s::AbstractString) = "'" * replace(String(s), "'" => "'\\''") * "'"

function start_finalize!(builder::BuildSession, name::String)
    token = lock(builder.lock) do
        builder.final_token += 1
        builder.final_state, builder.final_error = :waiting, ""
        builder.build_done, builder.alias_done = false, false
        builder.final_started = time()
        builder.final_token
    end
    task = Threads.@spawn begin
        dest, command = "", ""
        committed, owned_dest = false, false
        try
            dest = check_install(name)
            while true
                state = snapshot(builder)
                lock(builder.lock) do
                    builder.final_token == token || throw(NativeAgent.Cancelled())
                end
                failed = [(id, j) for (id, j) in state.jobs if j.state == :failed]
                isempty(failed) || error("$(skill(builder, first(failed)[1]).name): $(first(failed)[2].error)")
                any(j -> j.state == :running, values(state.jobs)) || break
                sleep(0.1)
            end
            state = snapshot(builder)
            all(j -> j.state == :done, values(state.jobs)) || error("A selected feature is not ready.")
            owners = Dict{String,String}()
            for (id, job) in state.jobs, name in job.tools
                previous = get(owners, name, nothing)
                previous === nothing || error("Tool '$name' is provided by both $(skill(builder, previous).name) and $(skill(builder, id).name).")
                owners[name] = id
            end
            lock(builder.lock) do
                builder.final_token == token || throw(NativeAgent.Cancelled())
                builder.final_state = :building
                builder.final_started = time()
            end
            mkpath(dirname(dest); mode=0o700)
            mkdir(dest; mode=0o700)
            owned_dest = true
            features = joinpath(dest, "features")
            mkdir(features; mode=0o700)
            ids = sort!(collect(keys(state.jobs)))
            for id in ids
                job = lock(builder.lock) do
                    builder.final_token == token || throw(NativeAgent.Cancelled())
                    get(builder.jobs, id, nothing)
                end
                job === nothing && throw(NativeAgent.Cancelled())
                cp(joinpath(job.dir, "feature.jl"), joinpath(features, id * ".jl"))
            end
            open(joinpath(dest, "profile.json"), "w") do io
                write(io, JSON.json(Dict("name" => name, "model" => builder.model,
                                         "window" => builder.window, "features" => ids)), '\n')
            end
            lock(builder.lock) do
                builder.final_token == token || throw(NativeAgent.Cancelled())
                builder.build_done = true
                record_duration!(builder, "build", time() - builder.final_started)
                builder.final_state, builder.final_started = :alias, time()
            end
            bin = bin_dir()
            mkpath(bin; mode=0o700)
            command = joinpath(bin, name)
            julia = first(Base.julia_cmd().exec)
            script = "#!/bin/sh\n" *
                     "export JULIAFOREVER_HOME=" * shellquote(ChatGPTAuth.config_dir()) * "\n" *
                     "export JULIAFOREVER_PROFILE=" * shellquote(dest) * "\n" *
                     "exec " * shellquote(julia) * " --startup-file=no --project=" * shellquote(ROOT) *
                     " " * shellquote(joinpath(ROOT, "run.jl")) * " \"\$@\"\n"
            temp, io = mktemp(bin)
            try
                write(io, script)
                close(io)
                chmod(temp, 0o755)
                lock(builder.lock) do
                    builder.final_token == token || throw(NativeAgent.Cancelled())
                    Base.Filesystem.hardlink(temp, command)
                    committed = true
                    builder.install_dir = dest
                    builder.alias_done = true
                    record_duration!(builder, "alias", time() - builder.final_started)
                    builder.final_state = :done
                end
            finally
                isopen(io) && close(io)
                rm(temp; force=true)
            end
        catch error
            !committed && owned_dest && isdir(dest) && try rm(dest; recursive=true, force=true) catch end
            lock(builder.lock) do
                if builder.final_token == token && !(error isa NativeAgent.Cancelled)
                    builder.final_state = :failed
                    builder.final_error = sprint(showerror, error)
                    builder.build_done = false
                end
            end
        end
    end
    lock(builder.lock) do
        push!(builder.tasks, task)
    end
    nothing
end

function cancel_finalize!(builder::BuildSession)
    lock(builder.lock) do
        builder.final_state == :done && return
        builder.final_token += 1
        builder.final_state, builder.final_error = :idle, ""
    end
end

function cleanup!(builder::BuildSession)
    cancel_finalize!(builder)
    jobs = lock(builder.lock) do
        collect(values(builder.jobs))
    end
    for job in jobs
        job.state == :running && Threads.@spawn NativeAgent.cancel!(job.control)
    end
    tasks = lock(builder.lock) do
        copy(builder.tasks)
    end
    if timedwait(() -> all(istaskdone, tasks), 4.0; pollint=0.05) != :timed_out
        try rm(builder.scratch; recursive=true, force=true) catch end
    end
end

end
