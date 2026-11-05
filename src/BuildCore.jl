module BuildCore

using JSON
import ..ChatGPTAuth
import ..HotReload
import ..NativeAgent

@kwdef struct Recipe
    id::String
    name::String
    description::String
    tools::Vector{Pair{String,Vector{String}}} = Pair{String,Vector{String}}[]
end

const RECIPES = [
    Recipe(id="steer-queue", name="Steer / queue", description="Steer a running turn or queue a follow-up."),
    Recipe(id="image", name="Image generation", description="Generate images with the Codex subscription.",
           tools=["generate_image" => ["prompt", "path", "host_model"],
                  "describe_image" => ["path", "question"]]),
    Recipe(id="microphone", name="Microphone", description="Record and transcribe with the Codex subscription.",
           tools=["transcribe_audio" => ["path"]]),
]
const ROOT = normpath(joinpath(@__DIR__, ".."))
bin_dir() = abspath(expanduser(get(ENV, "JULIAFOREVER_BIN", joinpath(homedir(), ".local", "bin"))))

mutable struct FeatureJob
    state::Symbol
    started::Float64
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
                 load_durations(), :idle, "", 0, false, false, 0.0, "")
end

function record_duration!(builder::BuildSession, key::String, seconds::Real)
    isfinite(seconds) && seconds > 0 || return
    values = get!(builder.durations, key, Float64[])
    push!(values, Float64(seconds))
    length(values) > 20 && deleteat!(values, 1:(length(values) - 20))
    try ChatGPTAuth.save_json("build-durations.json", builder.durations) catch end
end

function recipe(id::String)
    i = findfirst(r -> r.id == id, RECIPES)
    i === nothing && error("Unknown feature: $id")
    RECIPES[i]
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
- HTTP.sse_callback receives events whose .data is a String. Use status_exception=false,
  redirect=false, retry=false, proxy=HTTP.ProxyConfig(), and wrap requests in
  Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) so headers are never logged.
- Tool results are strings shown to the model. Return a short success message, or a string starting
  with "Error: " that never contains tokens, account ids, headers, data URLs, or raw request bodies.
- tool_schemas() returns a Vector of flat tool records: Dict("type" => "function", "name" =>
  name, "description" => text, "strict" => true, "parameters" => the JSON object schema). Do not
  nest the record under a "function" key, and do not omit "name" or the top-level "strict".
"""

function contract(selected::Recipe)
    if selected.id == "steer-queue"
        return """
Deliver steering and queued follow-ups from the composer while a turn is running.

tool_schemas() must return an empty vector: this feature exposes no agent tools.
run_tool must accept any name and return an empty string.

on_key!(menu, event, state) is the whole feature:
- Ignore key releases: return false when event.action is App.Tachikoma.key_release.
- While menu.busy and event.key is :enter: read the composer with App.Tachikoma.text(menu.prompt).
  When its stripped text is empty, consume the key and return true without doing more. Otherwise call
  App.queue_prompt!(menu, :steer) and return true.
- While menu.busy and event.key is :ctrl with event.char equal to 'g': call
  App.queue_prompt!(menu, :queue) and return true. Do not advertise Option+Enter; terminals may not
  distinguish its modifiers.
- In every other case return false, so ordinary typing, Enter while idle, arrows, scrolling, Escape
  and focus keys keep working.

footer returns exactly "enter steer  ctrl+g queue  ↑↓ scroll  ctrl+o tools" while menu.busy and an
empty string otherwise. The host agent loop already implements delivery, interruption and the
composer clearing performed by App.queue_prompt!; do not store prompts in state and do not add
notices of your own. on_frame! and shutdown! are no-ops.
"""
    elseif selected.id == "image"
        return """
Image generation and image description through the ChatGPT/Codex subscription, exposed as exactly
two agent tools.

tool_schemas() must return these two function schemas, with "strict" => true,
"additionalProperties" => false, and required parameters in this order:
1. generate_image: prompt (string), path (string, new .png output path relative to session.cwd or
   absolute), host_model (["string", "null"], null means gpt-6.1-sol).
2. describe_image: path (string), question (["string", "null"]).
Describe in each description that the image goes to the subscription and that session history is not
modified. run_tool routes by name; any other name returns "Error: Unknown live tool ...".

Credentials: prefer a Codex credential from joinpath(homedir(), ".codex", "auth.json"):
its tokens.access_token when it is a printable header value, plus tokens.account_id when present.
Otherwise use App.ChatGPTAuth.access_token() with no account header. Never print, log or return
tokens or account ids, and sanitize provider error text: remove bearer values, token-like words,
account ids, UUIDs, data URLs and long base64 runs, cap the detail length, and never surface an HTTP
exception message because it can contain request headers. Report your own short message instead.

generate_image:
- Require a path ending in .png, an existing parent directory, and nothing already at the path (file
  or symlink); otherwise return "Error: ...".
- POST to "https://chatgpt.com/backend-api/codex/responses" as an SSE stream with headers
  Authorization Bearer, "originator" => "JuliaForever", "OpenAI-Beta" => "responses=experimental",
  Content-Type application/json, Accept text/event-stream, User-Agent "juliaforever-image/1.0",
  plus ChatGPT-Account-ID when the credential has an account.
- Body: model is host_model when it is non-empty text else "gpt-6.1-sol"; store false; stream true;
  instructions "Generate the requested image. Do not add extra prose."; one user message whose
  content is one input_text item; tools containing {"type":"image_generation",
  "model":"gpt-image-2","size":"1024x1024"}; tool_choice {"type":"image_generation"}.
- Events: response.output_item.done may carry an item whose type is "image_generation_call" with a
  base64 result; response.completed may repeat those items in response.output; response.failed,
  response.incomplete and error report failure. Ignore event.data "[DONE]" and treat malformed JSON
  as a failure. Require a completed stream, a non-empty result, at most 24 MiB of base64, valid
  base64, and a complete PNG (signature plus IEND trailer).
- Publish through a private temporary file in the destination directory and a hard link so an
  existing file is never overwritten, removing the temporary file in all cases.
- Success returns "Saved PNG: " * path. Use connect timeout 15, request timeout 300 and read idle
  timeout 180 seconds.

describe_image:
- Read at most 20 MiB and require a PNG, JPEG, GIF or WebP signature.
- POST to "https://api.openai.com/v1/responses" with the same SSE headers, model = session.model,
  store false, stream true, instructions "Answer the user's question about the image.", and one user
  message with an input_text item (the question, or "Describe this image clearly and concisely."
  when it is null or blank) and an input_image item whose image_url is a data URL built from the
  detected MIME type and the base64 bytes.
- Accumulate response.output_text.delta text. If the stream completes with no deltas, take the
  output_text parts from response.output instead. Return the description text. Request timeout 240.

on_key!, on_frame!, footer and shutdown! must be defined no-ops returning false, nothing, "" and
nothing: this feature has no keyboard or footer behavior.
"""
    end
    return """
Microphone recording and transcription through the ChatGPT/Codex subscription, exposed as one tool
and a Ctrl+R recording flow.

tool_schemas() must return exactly one function schema with "strict" => true,
"additionalProperties" => false: transcribe_audio with required parameter path (string, relative to
session.cwd or absolute). It transcribes an existing file and never uses or deletes the microphone.
run_tool routes transcribe_audio and returns "Error: Unknown live tool ..." for other names.

Transcription request:
- Require a regular file larger than 44 bytes and at most 25 MiB.
- POST multipart to "https://chatgpt.com/backend-api/transcribe" with header field name "file" and a
  neutral filename derived from the extension, an audio MIME type for wav, mp3, mp4, m4a, mpeg,
  mpga, webm, ogg, flac or aiff, and otherwise application/octet-stream. Headers: Authorization
  Bearer, "originator" => "Codex Desktop", Accept application/json, plus ChatGPT-Account-ID when the
  credential has one. Prefer the Codex credential in joinpath(homedir(), ".codex", "auth.json"),
  else App.ChatGPTAuth.access_token(); never print tokens or account ids.
- Response JSON field "text" must be non-empty text. Use connect timeout 15, request timeout 180,
  redirect=false, retry=false, proxy=HTTP.ProxyConfig(), and cancel through an
  HTTP.RequestContext when the user cancels (HTTP.canceled(context) distinguishes cancellation).
- On 401 or 403 with the Codex credential, retry once with the app token when it differs. Sanitize
  every error: no bearer values, account ids, UUIDs, data URLs or long base64 runs.

capture (or the retry path) starts a Threads task that owns a job Dict with an events channel and an
atomic Int action (0 running, 1 stop requested, 2 cancel, 3 shutdown); the UI thread drains events in
on_frame!. Record on macOS only, with Sys.which("ffmpeg"); return a clear failure when ffmpeg or
avfoundation is missing. Write to a new .wav file in joinpath(App.ChatGPTAuth.ensure_dir(),
"recordings"), created with mode 0o700 and private files, using:
ffmpeg -hide_banner -loglevel error -nostdin -f avfoundation -i :default -t 600 -ac 1 -ar 16000
-c:a pcm_s16le -f wav -y FILE
Run it detached from stdin, keep stderr in a temporary log for diagnostics, cap the recording at 10
minutes, and stop with SIGINT so ffmpeg finalizes the WAV header; escalate to SIGKILL after 3 seconds.
A recording is usable when it is a file larger than 44 bytes.

UI behavior:
- Ctrl+R (event.key :ctrl, event.char 'r') starts recording when idle, stops when recording, retries
the upload when the previous attempt failed, and is ignored otherwise. Ignore key releases, and for
legacy terminals ignore repeated Ctrl+R bytes within 0.75 seconds.
- Escape cancels an active recording, upload or stop and keeps usable audio; Escape dismisses a
failed state while keeping the saved audio path.
- Insert the transcription into the composer at the cursor with App.save_edit! before splicing
  characters, replacing control characters with spaces and adding a separating space only when the
  neighbouring characters are not whitespace, then App.Tachikoma._run_validator!(menu.prompt).
- Keep usable recordings private on disk until text is actually inserted. A result that arrives after
  cancellation or for a different session is not inserted; report the saved path so Ctrl+R can retry.
- footer reports the phase concisely: starting, recording with the 10 minute cap and stop/cancel keys,
  stopping, transcribing, canceling with audio retained, saved audio with Ctrl+R retry and Escape
  dismiss, and otherwise the idle composer shortcuts shared with the host.
- on_frame! drains the job channel, applies those transitions, and must never block the UI thread.
  shutdown! cancels workers, signals the recorder with SIGINT then SIGKILL, and returns without
  waiting more than about 4 seconds total.

State is the persistent Dict{Symbol,Any} passed to every hook: keep the microphone phase, job, saved
path and last notice there so an active recording survives a feature reload.
"""
end

function build_prompt(selected::Recipe)
    "Build the $(selected.name) feature for JuliaForever in this isolated working directory. " *
    "Write the complete idiomatic Julia implementation yourself to feature.jl using your local tools; " *
    "no tests, documentation, or code comments. There is no reference implementation to copy and no " *
    "other feature source to read. " *
    "The file is included into a fresh module with a constant App referring to JuliaForever. " *
    "It must define six top-level functions: tool_schemas(), run_tool(session,name,args,state), " *
    "on_key!(menu,event,state), on_frame!(menu,state), footer(menu,state) and shutdown!(state), " *
    "including no-ops the contract does not otherwise use. Hooks may use App, Base, and packages " *
    "accessible through App. state is a persistent Dict{Symbol,Any} unique to this feature that " *
    "survives reloads; only Base and host values belong in it. Return false from unhandled on_key! " *
    "and an empty string from footer when no footer is needed. A feature file is self-contained: " *
    "helper files are not installed. Do not edit files outside this working directory. " *
    "This is an integration task: write feature.jl directly. Do not inspect unrelated files, search " *
    "recursively, read session logs, run tests, or explore the repository. The host interface " *
    "section below is complete; do not read package or standard library sources to verify it.\n\n" *
    HOST * "\n" * contract(selected)
end

function check_feature(selected::Recipe, generation)
    expected = selected.tools
    Set(keys(generation.names)) == Set(first.(expected)) ||
        error("The feature returned the wrong tool schemas.")
    schemas = Dict(get(schema, "name", "") => schema for schema in generation.schemas)
    for (name, parameters) in expected
        schema = schemas[name]
        get(schema, "strict", false) === true || error("The $name schema must be strict.")
        properties = get(get(schema, "parameters", nothing), "properties", nothing)
        properties isa AbstractDict || error("The $name schema has no object parameters.")
        Set(keys(properties)) == Set(parameters) || error("The $name schema has the wrong properties.")
        required = get(schema["parameters"], "required", nothing)
        (required isa AbstractVector && sort(String.(required)) == sort(parameters)) ||
            error("The $name schema has the wrong required parameters.")
        get(schema["parameters"], "additionalProperties", nothing) === false ||
            error("The $name schema must reject additional properties.")
    end
    generation
end

function start_feature!(builder::BuildSession, id::String)
    selected = recipe(id)
    job = lock(builder.lock) do
        haskey(builder.jobs, id) && return nothing
        dir = mktempdir(builder.scratch; prefix=id * "-")
        j = FeatureJob(:running, time(), dir, NativeAgent.TurnControl(), nothing, "")
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
            check_feature(selected, generation)
            lock(builder.lock) do
                if get(builder.jobs, id, nothing) === job && !job.control.cancelled[]
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
        jobs = Dict(id => (state=j.state, error=j.error) for (id, j) in builder.jobs)
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
