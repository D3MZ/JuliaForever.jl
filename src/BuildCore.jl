module BuildCore

using JSON
import ..ChatGPTAuth
import ..HotReload
import ..NativeAgent

struct Recipe
    id::String
    name::String
    description::String
end

const RECIPES = [Recipe("steer-queue", "Steer / queue", "Steer a running turn or queue a follow-up."),
                 Recipe("image", "Image generation", "Generate images with the Codex subscription."),
                 Recipe("microphone", "Microphone", "Record and transcribe with the Codex subscription.")]
const ROOT = normpath(joinpath(@__DIR__, ".."))
bin_dir() = abspath(expanduser(get(ENV, "JULIAFOREVER_BIN", joinpath(homedir(), ".local", "bin"))))

mutable struct FeatureJob
    recipe::Recipe
    state::Symbol
    started::Float64
    duration::Float64
    dir::String
    control::NativeAgent.TurnControl
    task::Union{Nothing,Task}
    error::String
end

mutable struct BuildSession
    model::String
    window::Int
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
    command::String
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
    scratch = mktempdir(; prefix="juliaforever-build-")
    chmod(scratch, 0o700)
    BuildSession(model, window, scratch, ReentrantLock(), Dict{String,FeatureJob}(), Task[],
                 load_durations(), :idle, "", 0, false, false, 0.0, "", "")
end

function record_duration!(builder::BuildSession, key::String, seconds::Real)
    isfinite(seconds) && seconds > 0 || return
    values = get!(builder.durations, key, Float64[])
    push!(values, Float64(seconds))
    length(values) > 20 && deleteat!(values, 1:length(values)-20)
    try ChatGPTAuth.save_json("build-durations.json", builder.durations) catch end
end

function recipe(id::String)
    i = findfirst(r -> r.id == id, RECIPES)
    i === nothing && error("Unknown feature: $id")
    RECIPES[i]
end

function build_prompt(selected::Recipe)
    common = "Build the $(selected.name) feature for JuliaForever in this isolated working directory. " *
        "Write the complete Julia source to feature.jl using your local tools; no tests or documentation. " *
        "The file is included into a fresh module with a constant App referring to JuliaForever. " *
        "It must define tool_schemas(), run_tool(session,name,args,state), on_key!(menu,event,state), " *
        "on_frame!(menu,state), footer(menu,state), and shutdown!(state). " *
        "Hooks may use App, Base, and packages accessible through App; state is a persistent Dict{Symbol,Any} " *
        "unique to this feature and survives reloads. Return false from unhandled on_key!, and an empty " *
        "string from footer if no footer is needed. Do not edit files outside this working directory. " *
        "This is a small integration task: write feature.jl directly. Do not inspect unrelated files, " *
        "search recursively, read session logs, run tests, or explore the repository. "
    if selected.id == "steer-queue"
        return common * "Implement this feature's keyboard adapter: while menu.busy, Enter sends the " *
            "composer as a steer using App.queue_prompt!(menu, :steer); Ctrl+G sends it as a queued " *
            "follow-up via App.queue_prompt!(menu, :queue). Tachikoma represents Ctrl+G as " *
            "event.key == :ctrl and event.char == 'g', and Enter as event.key == :enter. " *
            "Do not advertise Option+Enter; the terminal may not distinguish its modifiers. " *
            "Never intercept ordinary input or Enter while idle. " *
            "Expose no agent tools. Indicate the shortcuts concisely in footer while busy. " *
            "The host's agent loop supplies actual delivery and interruption semantics."
    end
    reference = joinpath(ROOT, "src", "LiveFeatures.jl")
    common *= "Reuse the already working native implementation at $(reference): load it into a separate " *
        "module whose App constant is the host App, and forward only this feature's hooks and schemas. " *
        "Use Base.invokelatest when calling methods loaded into that module. Do not copy credentials. "
    if selected.id == "microphone"
        common * "Expose only its transcribe_audio tool and forward its microphone on_key!, on_frame!, " *
            "footer, shutdown!, and run_tool hooks. Preserve Ctrl+R recording, retry and cancellation behavior."
    else
        common * "Expose only its generate_image and describe_image tools and forward run_tool. " *
            "Do not enable the microphone hooks from the shared implementation."
    end
end

function start_feature!(builder::BuildSession, id::String)
    selected = recipe(id)
    job = lock(builder.lock) do
        haskey(builder.jobs, id) && return nothing
        dir = mktempdir(builder.scratch; prefix=id * "-")
        j = FeatureJob(selected, :running, time(), 0.0, dir, NativeAgent.TurnControl(), nothing, "")
        builder.jobs[id] = j
        j
    end
    job === nothing && return
    task = Threads.@spawn begin
        try
            session = NativeAgent.Session(builder.model, builder.window, job.dir; remember=false)
            NativeAgent.run_turn!(session, build_prompt(selected), (kind, value) -> nothing;
                                  control=job.control, live=false)
            job.control.cancelled[] && throw(NativeAgent.Cancelled())
            path = joinpath(job.dir, "feature.jl")
            isfile(path) || error("The builder did not write feature.jl.")
            source = read(path, String)
            isempty(strip(source)) && error("The builder returned an empty feature.")
            manager = HotReload.CURRENT[]
            manager === nothing && error("Live feature manager is unavailable.")
            generation = HotReload.candidate(manager, Pair{String,String}[path => source])
            required = selected.id == "microphone" ? Set(["transcribe_audio"]) :
                       selected.id == "image" ? Set(["generate_image", "describe_image"]) : Set{String}()
            Set(keys(generation.names)) == required || error("The feature returned the wrong tool schemas.")
            lock(builder.lock) do
                if get(builder.jobs, id, nothing) === job && !job.control.cancelled[]
                    job.state, job.duration = :done, time() - job.started
                    record_duration!(builder, id, job.duration)
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
    # Do not wait for a network cancellation or filesystem cleanup on the UI thread.
    Threads.@spawn begin
        NativeAgent.cancel!(job.control)
        job.task === nothing || try wait(job.task) catch end
        try rm(job.dir; recursive=true, force=true) catch end
    end
    nothing
end

function snapshot(builder::BuildSession)
    lock(builder.lock) do
        jobs = Dict(id => (state=j.state, error=j.error, started=j.started, duration=j.duration)
                    for (id, j) in builder.jobs)
        (jobs=jobs, state=builder.final_state, error=builder.final_error,
         build_done=builder.build_done, alias_done=builder.alias_done,
         install_dir=builder.install_dir, command=builder.command)
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
                isempty(failed) || error("$(recipe(first(failed)[1]).name): $(first(failed)[2].error)")
                any(j -> j.state == :running, values(state.jobs)) || break
                sleep(0.1)
            end
            state = snapshot(builder)
            all(j -> j.state == :done, values(state.jobs)) || error("A selected feature is not ready.")
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
            script = "#!/bin/sh\n# JuliaForever profile\n" *
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
                    builder.command, builder.install_dir = command, dest
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
