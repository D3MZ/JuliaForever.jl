module BuildCore

using TOML

export Recipe, RECIPES, BuildSession, FeatureJob, start_feature!, remove_feature!,
       start_finalize!, cancel_finalize!, cleanup!, progress, estimate, pi_models,
       auth_type, pi_path, build_error, data_root, bin_dir

struct Recipe
    id::String
    name::String
    description::String
    usage::String
end

const RECIPES = [
    Recipe("caesar-cipher", "Caesar cipher", "Encode and decode Caesar ciphers.",
           "Run `julia --startup-file=no <skill-directory>/main.jl encode|decode SHIFT TEXT`. Quote the text as one shell argument. Preserve the user's text exactly."),
    Recipe("github", "GitHub", "Inspect a GitHub repository and its open issues using gh.",
           "For read-only inspection, run `julia --startup-file=no <skill-directory>/main.jl repo [OWNER/REPO]` or `julia --startup-file=no <skill-directory>/main.jl issues [OWNER/REPO]`. The user must have gh installed and authenticated. Never imply these commands can make changes."),
    Recipe("project-overview", "Project overview", "Summarize a local project's file types and markers.",
           "Run `julia --startup-file=no <skill-directory>/main.jl [DIRECTORY]` to inspect a project without changing files. Ask before examining a directory outside the user's requested workspace."),
]

const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
data_root() = abspath(expanduser(get(ENV, "JULIAFOREVER_HOME", joinpath(homedir(), ".local", "share", "juliaforever"))))
bin_dir() = abspath(expanduser(get(ENV, "JULIAFOREVER_BIN", joinpath(homedir(), ".local", "bin"))))
pi_path() = something(Sys.which("pi"), "")

function query_pi(args::Vector{String}; timeout::Real=10)
    pi = pi_path()
    isempty(pi) && error("Pi is not installed or is not on PATH.")
    path, out = mktemp()
    proc = nothing
    try
        proc = run(pipeline(Cmd(vcat([pi], args)); stdin=devnull, stdout=out, stderr=devnull); wait=false)
        if timedwait(() -> !process_running(proc), timeout; pollint=0.05) == :timed_out
            try kill(proc, Base.SIGKILL) catch end
            error("Pi did not respond within $(timeout) seconds.")
        end
        wait(proc)
        success(proc) || return nothing
        flush(out)
        read(path, String)
    finally
        proc === nothing || !process_running(proc) || try kill(proc, Base.SIGKILL) catch end
        isopen(out) && close(out)
        isfile(path) && rm(path; force=true)
    end
end

function auth_type(provider::String)
    output = query_pi(["auth", "check", "--provider", provider, "--json", "--no-refresh"])
    output === nothing && return :none
    match(r"\"status\"\s*:\s*\"ready\"", output) === nothing && return :none
    found = match(r"\"authType\"\s*:\s*\"(oauth|api_key)\"", output)
    found === nothing ? :unknown : Symbol(found.captures[1])
end

function pi_models()
    output = query_pi(["--list-models"])
    output === nothing && error("Could not load models from Pi.")
    result = Tuple{String,String}[]
    in_table = false
    for line in split(output, '\n')
        parts = split(strip(line))
        length(parts) >= 2 || continue
        if parts[1] == "provider" && parts[2] == "model"
            in_table = true
            continue
        end
        in_table || continue
        push!(result, (String(parts[1]), String(parts[2])))
    end
    unique!(result)
    result
end

mutable struct FeatureJob
    recipe::Recipe
    state::Symbol
    started::Float64
    duration::Float64
    dir::String
    process::Union{Nothing,Base.Process}
    task::Union{Nothing,Task}
    error::String
end

mutable struct BuildSession
    provider::String
    model::String
    jobs::Dict{String,FeatureJob}
    tasks::Vector{Task}
    scratch::String
    history::Dict{String,Vector{Float64}}
    history_lock::ReentrantLock
    final_state::Symbol
    final_error::String
    final_token::Int
    build_done::Bool
    alias_done::Bool
    build_started::Float64
    alias_started::Float64
    command::String
    install_dir::String
end

function load_history()
    file = joinpath(data_root(), "durations.toml")
    isfile(file) || return Dict{String,Vector{Float64}}()
    try
        data = TOML.parsefile(file)
        Dict(String(k) => Float64[x for x in v if x isa Real && isfinite(x) && x > 0]
             for (k, v) in get(data, "durations", Dict()) if v isa Vector)
    catch
        Dict{String,Vector{Float64}}()
    end
end

function BuildSession(provider::String, model::String)
    scratch = mktempdir(; prefix="juliaforever-")
    chmod(scratch, 0o700)
    BuildSession(provider, model, Dict{String,FeatureJob}(), Task[], scratch, load_history(), ReentrantLock(),
                 :idle, "", 0, false, false, 0.0, 0.0, "", "")
end

function record_duration!(session::BuildSession, key::String, seconds::Real)
    isfinite(seconds) && seconds > 0 || return
    lock(session.history_lock) do
        values = get!(session.history, key, Float64[])
        push!(values, Float64(seconds))
        length(values) > 20 && deleteat!(values, 1:length(values)-20)
        try
            mkpath(data_root(); mode=0o700)
            verify_owned_dir(data_root())
            path = joinpath(data_root(), "durations.toml")
            temp, io = mktemp(data_root())
            try
                TOML.print(io, Dict("durations" => session.history))
                close(io)
                chmod(temp, 0o600)
                mv(temp, path; force=true)
            finally
                isopen(io) && close(io)
                isfile(temp) && rm(temp; force=true)
            end
        catch
            # History is advisory; never turn a successful build into a failure.
        end
    end
end

function recipe(id::String)
    i = findfirst(r -> r.id == id, RECIPES)
    i === nothing && error("Unknown feature: $id")
    RECIPES[i]
end

function extract_source(output::String)
    source = strip(output)
    fenced = match(r"(?s)^```(?:julia)?\s*\n(.*)\n```\s*$", source)
    fenced === nothing || (source = strip(fenced.captures[1]))
    isempty(source) && error("The build agent returned no source.")
    parsed = Meta.parseall(source)
    function invalid(node)
        node isa Expr || return false
        node.head in (:error, :incomplete) || any(invalid, node.args)
    end
    invalid(parsed) && error("The build agent returned invalid Julia source.")
    source * "\n"
end

function error_excerpt(path::String)
    isfile(path) || return "Pi exited without an error message."
    message = strip(read(path, String))
    isempty(message) && return "Pi exited without an error message."
    lines = split(message, '\n')
    first(join(last(lines, min(length(lines), 3)), " "), 350)
end

function start_feature!(session::BuildSession, id::String)
    haskey(session.jobs, id) && return session.jobs[id]
    selected = recipe(id)
    work = mktempdir(session.scratch; prefix=id * "-")
    job = FeatureJob(selected, :running, time(), 0.0, work, nothing, nothing, "")
    session.jobs[id] = job
    job.task = @async begin
        output = joinpath(work, "output.txt")
        errors = joinpath(work, "error.txt")
        try
            skill = read(joinpath(REPO_ROOT, "skills", id, "SKILL.md"), String)
            prompt = "You are one implementation worker. Do not delegate or call tools. " *
                     "Implement only the following feature skill. Return one complete Julia source file " *
                     "as plain text, without Markdown or commentary. Do not build automated tests.\n\n" * skill
            pi = pi_path()
            isempty(pi) && error("Pi is not installed or is not on PATH.")
            args = [pi, "--provider", session.provider, "--model", session.model, "--thinking", "max",
                    "--no-tools", "--no-extensions", "--no-mcp", "--no-skills", "--no-context-files",
                    "--no-session", "--no-approve", "--print", "--", prompt]
            open(output, "w") do out
                open(errors, "w") do err
                    job.state == :cancelled && return
                    proc = run(pipeline(Cmd(Cmd(args); detach=Sys.isunix()); stdin=devnull, stdout=out, stderr=err); wait=false)
                    job.process = proc
                    wait(proc)
                    job.process = nothing
                    job.state == :cancelled && return
                    success(proc) || error(error_excerpt(errors))
                end
            end
            if job.state != :cancelled
                source = extract_source(read(output, String))
                write(joinpath(work, "main.jl"), source)
                job.duration = time() - job.started
                job.state = :done
                record_duration!(session, "feature:" * id, job.duration)
            end
        catch e
            if job.state != :cancelled
                job.error = sprint(showerror, e)
                job.state = :failed
            end
        finally
            job.process = nothing
            if job.state == :cancelled
                isdir(work) && rm(work; force=true, recursive=true)
            end
        end
    end
    push!(session.tasks, job.task)
    job
end

function signal_worker(proc::Base.Process, signal::Integer)
    process_running(proc) || return
    if Sys.isunix()
        pid = getpid(proc)
        group = ccall(:getpgid, Cint, (Cint,), pid)
        if group == pid
            ccall(:kill, Cint, (Cint, Cint), -pid, signal) == 0 || kill(proc, signal)
            return
        end
    end
    kill(proc, signal)
end

function stop_worker!(session::BuildSession, job::FeatureJob)
    proc = job.process
    proc === nothing && return
    process_running(proc) || return
    try signal_worker(proc, Base.SIGTERM) catch end
    task = @async begin
        if timedwait(() -> !process_running(proc), 1.0; pollint=0.05) == :timed_out
            try signal_worker(proc, Base.SIGKILL) catch end
        end
    end
    push!(session.tasks, task)
end

function remove_feature!(session::BuildSession, id::String)
    job = pop!(session.jobs, id, nothing)
    job === nothing && return
    job.state = :cancelled
    stop_worker!(session, job)
    if job.task === nothing || istaskdone(job.task)
        isdir(job.dir) && rm(job.dir; force=true, recursive=true)
    end
end

function history_mean(session::BuildSession, key::String)
    xs = get(session.history, key, Float64[])
    isempty(xs) ? nothing : sum(xs) / length(xs)
end

function estimate(session::BuildSession)
    selected = collect(values(session.jobs))
    any(j -> j.state == :failed, selected) && return nothing
    remaining = Float64[]
    for job in selected
        job.state == :done && continue
        value = history_mean(session, "feature:" * job.recipe.id)
        value === nothing && return nothing
        push!(remaining, max(1.0, value - (time() - job.started)))
    end
    feature_time = isempty(remaining) ? 0.0 : maximum(remaining)
    total = feature_time
    if !session.build_done
        value = history_mean(session, "build")
        value === nothing && return nothing
        total += session.final_state == :building ? max(0.0, value - (time() - session.build_started)) : value
    end
    if !session.alias_done
        value = history_mean(session, "alias")
        value === nothing && return nothing
        total += session.final_state == :alias ? max(0.0, value - (time() - session.alias_started)) : value
    end
    ceil(Int, total)
end

progress(session::BuildSession) =
    (count(j -> j.state == :done, values(session.jobs)) + Int(session.build_done) + Int(session.alias_done),
     length(session.jobs) + 2)
build_error(session::BuildSession) = session.final_error

function shellquote(value::String)
    "'" * replace(value, "'" => "'\\''") * "'"
end

function runtime_skill(recipe::Recipe)
    julia = shellquote(first(Base.julia_cmd().exec))
    usage = replace(recipe.usage, "julia --startup-file=no" => julia * " --startup-file=no")
    "---\nname: jf-$(recipe.id)\ndescription: $(recipe.description)\n---\n\n" *
    "# $(recipe.name)\n\nThe generated program is untrusted and has only been syntax-checked. " *
    "Inspect its source before running it. Resolve `<skill-directory>` relative to this SKILL.md. " * usage * "\n"
end

function launch_source(provider::String, model::String, ids::Vector{String})
    # repr produces Julia string literals rather than interpolating shell commands.
    """
    # Generated by JuliaForever. Pi supplies the agent loop and tools.
    pi = Sys.which("pi")
    if pi === nothing
        println(stderr, "Pi is not on PATH. Install Pi and sign in before launching.")
        exit(1)
    end
    instructions = string("This JuliaForever harness is installed at ", @__DIR__,
                          ". Its launcher is launch.jl; selected skill instructions and Julia programs are in skills/. ",
                          "Generated feature programs are untrusted; inspect their source before running them. ",
                          "Inspect and improve this harness when the user asks. Changes to its launcher or skill ",
                          "instructions take effect on a later launch; do not claim they are already reloaded.")
    args = String[pi, "--provider", $(repr(provider)), "--model", $(repr(model)),
                  "--thinking", "max", "--no-extensions", "--no-mcp", "--no-skills",
                  "--append-system-prompt", instructions]
    for id in $(repr(ids))
        append!(args, ["--skill", joinpath(@__DIR__, "skills", id, "SKILL.md")])
    end
    append!(args, ARGS)
    run(Cmd(args))
    """
end

function validate_name(name::String)
    occursin(r"^[A-Za-z][A-Za-z0-9_-]{0,63}$", name) ||
        error("Use 1–64 letters, numbers, hyphens or underscores; start with a letter.")
    name
end

function verify_owned_dir(path::String)
    islink(path) && error("Directory must not be a symlink: $path")
    ispath(path) || return
    isdir(path) || error("Not a directory: $path")
    if Sys.isunix()
        info = stat(path)
        info.uid == Libc.getuid() || error("Directory must be owned by your user: $path")
        info.mode & 0o022 == 0 || error("Directory must not be writable by other users: $path")
    end
end

function check_install_available(name::String)
    Sys.isunix() || error("The generated command currently requires a POSIX environment.")
    validate_name(name)
    bin = bin_dir()
    for path in (data_root(), joinpath(data_root(), "harnesses"), bin)
        verify_owned_dir(path)
    end
    any(p -> abspath(expanduser(isempty(p) ? "." : p)) == bin, split(get(ENV, "PATH", ""), Sys.iswindows() ? ';' : ':')) ||
        error("Add $(bin) to PATH, then retry. Existing shell settings were not changed.")
    existing = Sys.which(name)
    existing === nothing || error("Command '$name' already exists; choose another name.")
    command = joinpath(bin, name)
    (ispath(command) || islink(command)) && error("Command '$name' already exists; choose another name.")
    destination = joinpath(data_root(), "harnesses", name)
    (ispath(destination) || islink(destination)) && error("Harness '$name' already exists; choose another name.")
    destination
end

function prepare_install!(session::BuildSession, name::String)
    destination = check_install_available(name)
    mkpath(dirname(destination); mode=0o700)
    for path in (data_root(), dirname(destination))
        verify_owned_dir(path)
    end
    mkdir(destination; mode=0o700)
    try
        ids = sort!(collect(keys(session.jobs)))
        for id in ids
            job = session.jobs[id]
            job.state == :done || error("Feature $(job.recipe.name) is not ready.")
            target = joinpath(destination, "skills", id)
            mkpath(target; mode=0o700)
            cp(joinpath(job.dir, "main.jl"), joinpath(target, "main.jl"))
            write(joinpath(target, "SKILL.md"), runtime_skill(job.recipe))
        end
        write(joinpath(destination, "launch.jl"), launch_source(session.provider, session.model, ids))
        open(joinpath(destination, "manifest.toml"), "w") do io
            TOML.print(io, Dict("name" => name, "provider" => session.provider, "model" => session.model, "features" => ids))
        end
        session.install_dir = destination
    catch
        rm(destination; recursive=true, force=true)
        rethrow()
    end
end

function install_command!(session::BuildSession, name::String, token::Int)
    bin = bin_dir()
    mkpath(bin; mode=0o700)
    verify_owned_dir(bin)
    target = joinpath(bin, name)
    (ispath(target) || islink(target)) && error("Command '$name' already exists; choose another name.")
    julia = first(Base.julia_cmd().exec)
    script = "#!/bin/sh\n# Generated by JuliaForever.\nexec " * shellquote(julia) *
             " --startup-file=no " * shellquote(joinpath(session.install_dir, "launch.jl")) * " \"\$@\"\n"
    temp, io = mktemp(bin)
    try
        write(io, script)
        close(io)
        chmod(temp, 0o755)
        session.final_token == token || error("Installation cancelled before publishing the command.")
        Base.Filesystem.hardlink(temp, target) # Commit point: atomic and never overwrites.
        session.command = target
    finally
        isopen(io) && close(io)
        try
            isfile(temp) && rm(temp; force=true)
        catch
            isempty(session.command) && rethrow()
            println(stderr, "Warning: could not remove temporary command file ", temp)
        end
    end
end

function start_finalize!(session::BuildSession, name::String)
    session.final_token += 1
    token = session.final_token
    session.final_state = :waiting
    session.final_error = ""
    session.build_done = false
    session.alias_done = false
    task = @async begin
        try
            check_install_available(name)
            while any(j -> j.state == :running, values(session.jobs))
                session.final_token == token || return
                failed = [j for j in values(session.jobs) if j.state == :failed]
                isempty(failed) || error("$(first(failed).recipe.name) failed: $(first(failed).error)")
                sleep(0.1)
            end
            session.final_token == token || return
            failed = [j for j in values(session.jobs) if j.state != :done]
            isempty(failed) || error("$(first(failed).recipe.name) failed: $(first(failed).error)")
            session.final_state = :building
            session.build_started = time()
            prepare_install!(session, name)
            session.build_done = true
            record_duration!(session, "build", time() - session.build_started)
            if session.final_token != token
                isdir(session.install_dir) && rm(session.install_dir; recursive=true, force=true)
                session.install_dir = ""
                session.build_done = false
                return
            end
            session.final_state = :alias
            session.alias_started = time()
            try
                install_command!(session, name, token)
            catch
                isdir(session.install_dir) && rm(session.install_dir; recursive=true, force=true)
                session.install_dir = ""
                session.build_done = false
                rethrow()
            end
            session.alias_done = true
            record_duration!(session, "alias", time() - session.alias_started)
            session.final_state = :done
        catch e
            if session.final_token == token
                session.final_error = sprint(showerror, e)
                session.final_state = :failed
            end
        end
    end
    push!(session.tasks, task)
end

function cancel_finalize!(session::BuildSession)
    session.final_token += 1
    session.final_state = :idle
    session.final_error = ""
end

function cleanup!(session::BuildSession)
    cancel_finalize!(session)
    jobs = collect(values(session.jobs))
    for job in jobs
        if job.state == :running
            job.state = :cancelled
            stop_worker!(session, job)
        end
    end
    if timedwait(() -> all(istaskdone, session.tasks), 4.0; pollint=0.05) == :timed_out
        println(stderr, "A build did not stop; its temporary files remain at ", session.scratch)
    else
        isdir(session.scratch) && rm(session.scratch; recursive=true, force=true)
    end
end

end
