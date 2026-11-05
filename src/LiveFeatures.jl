# This body is reloaded in isolation. Only Base/host types are kept in `state`,
# so an active recording and its worker survive a feature-generation change.
const HTTP = App.NativeAgent.HTTP
const JSON = App.JSON
const TRANSCRIBE_URL = "https://chatgpt.com/backend-api/transcribe"
const MAX_AUDIO_BYTES = 25 * 1024 * 1024

struct TranscriptionError <: Exception
    message::String
end

function tool_schemas()
    Any[Dict("type" => "function", "name" => "transcribe_audio", "strict" => true,
        "description" => "Transcribe an existing local audio file with the ChatGPT/Codex subscription. Does not use the microphone or delete the file.",
        "parameters" => Dict("type" => "object", "properties" => Dict(
            "path" => Dict("type" => "string", "description" => "Path to the audio file, relative to the session working directory or absolute.")),
            "required" => ["path"], "additionalProperties" => false)),
        Dict("type" => "function", "name" => "describe_image", "strict" => true,
            "description" => "Describe a local PNG, JPEG, WebP, or GIF image using the current session model. The image is sent to the OpenAI Responses endpoint; the conversation is not modified.",
            "parameters" => Dict("type" => "object", "properties" => Dict(
                "path" => Dict("type" => "string", "description" => "Local image path, relative to the session working directory or absolute."),
                "question" => Dict("type" => ["string", "null"], "description" => "What to describe, or null for a general description.")),
                "required" => ["path", "question"], "additionalProperties" => false)),
        Dict("type" => "function", "name" => "generate_image", "strict" => true,
            "description" => "Generate a PNG with the ChatGPT/Codex subscription and save it at a new local path without overwriting existing files.",
            "parameters" => Dict("type" => "object", "properties" => Dict(
                "prompt" => Dict("type" => "string", "description" => "Description of the requested image."),
                "path" => Dict("type" => "string", "description" => "New output PNG path, relative to the session working directory or absolute."),
                "host_model" => Dict("type" => ["string", "null"], "description" => "Optional Codex host model, or null for gpt-6.1-sol.")),
                "required" => ["prompt", "path", "host_model"], "additionalProperties" => false))]
end

# Only safe, explicitly selected server fields are shown; never show an HTTP
# exception, headers, raw body, token, or account ID in the UI or tool output.
function safe_detail(response, secrets)
    data = try JSON.parse(String(copy(response.body))) catch; nothing end
    data isa AbstractDict || return ""
    item = get(data, "error", nothing)
    fields = Any[]
    if item isa AbstractDict
        append!(fields, (get(item, "code", nothing), get(item, "message", nothing)))
    elseif item isa AbstractString
        push!(fields, item)
    end
    append!(fields, (get(data, "detail", nothing), get(data, "message", nothing)))
    pieces = String[]
    for field in fields
        field isa AbstractString || continue
        text = String(field)
        for secret in secrets
            secret isa AbstractString && !isempty(secret) && (text = replace(text, secret => "[redacted]"))
        end
        text = replace(text, r"(?i)bearer\s+[^\s,;]+" => "Bearer [redacted]")
        text = replace(text, r"(?i)(access[_ -]?token|api[_ -]?key|account[_ -]?id|authorization)\s*[:=]\s*[^\s,;]+" => "[redacted]")
        text = replace(text, r"eyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+" => "[redacted]")
        text = replace(text, r"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b" => "[redacted]")
        text = join((iscntrl(c) ? ' ' : c for c in text))
        text = strip(text)
        isempty(text) || push!(pieces, first(text, 280))
    end
    join(unique(pieces), "; ")
end

function valid_header(value)
    value isa AbstractString && !isempty(value) && all(c -> '!' <= c <= '~', value)
end

function codex_credentials()
    path = joinpath(homedir(), ".codex", "auth.json")
    data = try JSON.parsefile(path) catch; nothing end
    data isa AbstractDict || return nothing
    tokens = get(data, "tokens", nothing)
    tokens isa AbstractDict || return nothing
    token = get(tokens, "access_token", nothing)
    valid_header(token) || return nothing
    account = get(tokens, "account_id", nothing)
    (token=String(token), account=valid_header(account) ? String(account) : "", source="Codex")
end

function app_credentials()
    # Refresh through the app's normal OpenAI sign-in flow if necessary; only
    # the resulting access token is sent to the fixed transcription endpoint.
    token = try App.ChatGPTAuth.access_token() catch; nothing end
    valid_header(token) || return nothing
    (token=String(token), account="", source="JuliaForever")
end

function mime_for(path)
    ext = lowercase(splitext(path)[2])
    mime = get(Dict(".wav" => "audio/wav", ".mp3" => "audio/mpeg",
                    ".mp4" => "audio/mp4", ".m4a" => "audio/mp4",
                    ".mpeg" => "audio/mpeg", ".mpga" => "audio/mpeg",
                    ".webm" => "audio/webm", ".ogg" => "audio/ogg",
                    ".flac" => "audio/flac", ".aiff" => "audio/aiff"), ext, "application/octet-stream")
    # Do not send the user's original filename or allow header injection.
    name = occursin(r"^\.[a-z0-9]{1,8}$", ext) ? "audio" * ext : "audio.bin"
    name, mime
end

function upload_once(path, credential, context)
    name, mime = mime_for(path)
    headers = Pair{String,String}["Authorization" => "Bearer " * credential.token,
                                  "originator" => "Codex Desktop", "Accept" => "application/json"]
    isempty(credential.account) || push!(headers, "ChatGPT-Account-ID" => credential.account)
    response = try
        Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
            open(path, "r") do file
                form = HTTP.Form(["file" => HTTP.Multipart(name, file, mime)])
                # Direct TLS to this literal host only; no redirects, proxy, or
                # automatic retries can forward a bearer token elsewhere.
                HTTP.post(TRANSCRIBE_URL, headers, form; status_exception=false,
                          redirect=false, retry=false, proxy=HTTP.ProxyConfig(),
                          context=context, connect_timeout=15, request_timeout=180)
            end
        end
    catch
        HTTP.canceled(context) && throw(TranscriptionError("Transcription canceled."))
        throw(TranscriptionError("Could not upload audio to chatgpt.com. Check the connection and try again."))
    end
    if !(200 <= response.status < 300)
        detail = safe_detail(response, (credential.token, credential.account))
        message = "$(credential.source) HTTP $(response.status)" * (isempty(detail) ? "" : ": " * detail)
        return nothing, message, Int(response.status)
    end
    data = try JSON.parse(String(copy(response.body))) catch; nothing end
    text = data isa AbstractDict ? get(data, "text", nothing) : nothing
    text isa AbstractString && !isempty(strip(text)) ||
        throw(TranscriptionError("ChatGPT returned HTTP $(response.status), but no transcription text."))
    String(text), "", Int(response.status)
end

function transcribe_audio(path::String; context=HTTP.RequestContext())
    isfile(path) || throw(TranscriptionError("Audio file not found or not a regular file."))
    bytes = try filesize(path) catch; 0 end
    0 < bytes <= MAX_AUDIO_BYTES || throw(TranscriptionError("Audio file is empty or exceeds the 25 MiB upload limit."))
    HTTP.canceled(context) && throw(TranscriptionError("Transcription canceled."))
    credential = codex_credentials()
    credential === nothing && (credential = app_credentials())
    credential === nothing && throw(TranscriptionError("No current ChatGPT/Codex OAuth access token. Sign in or refresh the sign-in in Codex or JuliaForever, then retry."))
    HTTP.canceled(context) && throw(TranscriptionError("Transcription canceled."))
    text, failure, status = upload_once(path, credential, context)
    text === nothing || return text
    # Some accounts have only one of the two OAuth grants. Retry an explicit
    # authorization rejection with the app's own token, never with a new host.
    if credential.source == "Codex" && status in (401, 403) && !HTTP.canceled(context)
        alternative = app_credentials()
        if alternative !== nothing && alternative.token != credential.token
            try
                text, other_failure, _ = upload_once(path, alternative, context)
                text === nothing || return text
                failure *= "; " * other_failure
            catch e
                HTTP.canceled(context) && rethrow()
                detail = e isa TranscriptionError ? e.message : "Could not upload audio."
                throw(TranscriptionError(failure * "; JuliaForever: " * detail))
            end
        end
    end
    throw(TranscriptionError(failure * ". Check the subscription/sign-in and retry."))
end

function run_tool(session, name, args, state)
    name in ("describe_image", "generate_image") && return run_image_tool(session, name, args)
    name == "transcribe_audio" || error("Unknown live tool: $name")
    path = get(args, "path", nothing)
    path isa AbstractString && !isempty(path) || return "Error: Supply an audio file path."
    root = session === nothing ? pwd() : session.cwd
    path = expanduser(String(path))
    path = isabspath(path) ? normpath(path) : normpath(joinpath(root, path))
    try
        transcribe_audio(path)
    catch e
        e isa TranscriptionError ? "Error: " * e.message : "Error: Could not read or transcribe the audio file."
    end
end

function mic_state(state)
    get!(state, :microphone) do
        Dict{Symbol,Any}(:phase => :idle, :job => nothing, :path => "", :note => "")
    end
end

function new_job(session)
    Dict{Symbol,Any}(:session => session, :events => Channel{Any}(8),
                     :action => Threads.Atomic{Int}(0), :context => HTTP.RequestContext(),
                     :lock => ReentrantLock(), :process => nothing, :task => nothing)
end

function audio_usable(path)
    !isempty(path) && isfile(path) && (try filesize(path) > 44 catch; false end)
end

function recording_file()
    dir = joinpath(App.ChatGPTAuth.ensure_dir(), "recordings")
    mkpath(dir; mode=0o700)
    chmod(dir, 0o700)
    path, file = mktemp(dir; cleanup=false)
    close(file)
    wav = path * ".wav"
    try
        mv(path, wav)
    catch
        rm(path; force=true)
        rethrow()
    end
    wav
end

function capture_error(logpath)
    log = try read(logpath, String) catch; "" end
    log = strip(join((iscntrl(c) ? ' ' : c for c in log)))
    detail = isempty(log) ? "" : " " * last(log, min(length(log), 400))
    if occursin("avfoundation", lowercase(log)) && occursin("unknown", lowercase(log))
        return "This ffmpeg has no avfoundation input. Install an ffmpeg build with avfoundation." * detail
    end
    "Microphone capture failed. Check the default input and allow microphone access in macOS System Settings → Privacy & Security → Microphone." * detail
end

function signal_process(job, signal)
    lock(job[:lock]) do
        process = job[:process]
        process === nothing || try kill(process, signal) catch end
    end
end

function upload_worker(job, path)
    try
        if job[:action][] >= 2
            put!(job[:events], (:canceled, path))
            return
        end
        text = transcribe_audio(path; context=job[:context])
        if job[:action][] >= 2
            put!(job[:events], (:canceled, path))
        else
            put!(job[:events], (:result, path, text))
        end
    catch e
        if job[:action][] >= 2
            put!(job[:events], (:canceled, path))
        else
            message = e isa TranscriptionError ? e.message : "Could not transcribe the recording."
            put!(job[:events], (:failure, message, path))
        end
    end
end

function capture_worker(job)
    path, logpath, logio = "", "", nothing
    process = nothing
    try
        if !Sys.isapple()
            put!(job[:events], (:failure, "Microphone capture requires macOS and ffmpeg with avfoundation.", "")); return
        end
        ffmpeg = Sys.which("ffmpeg")
        if ffmpeg === nothing
            put!(job[:events], (:failure, "ffmpeg was not found. Install ffmpeg with avfoundation and restart the app if PATH changed.", "")); return
        end
        path = recording_file()
        logpath, logio = mktemp(dirname(path); cleanup=false)
        if job[:action][] >= 2
            put!(job[:events], (:canceled, "")); return
        end
        # -t limits encoded audio; the monotonic deadline below also covers a
        # stalled device. SIGINT makes ffmpeg finalize the WAV header.
        command = Cmd([ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin",
                       "-f", "avfoundation", "-i", ":default", "-t", "600",
                       "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le",
                       "-f", "wav", "-y", path])
        process = run(pipeline(ignorestatus(command); stdin=devnull, stdout=devnull, stderr=logio); wait=false)
        lock(job[:lock]) do
            job[:process] = process
        end
        put!(job[:events], (:recording, path))
        started, signaled, signaled_at = time_ns(), false, UInt64(0)
        requested = false
        while process_running(process)
            action = job[:action][]
            if !signaled && (action != 0 || (time_ns() - started) / 1e9 >= 600)
                requested = true
                signal_process(job, Base.SIGINT)
                signaled, signaled_at = true, time_ns()
            elseif signaled && (time_ns() - signaled_at) / 1e9 >= 3
                signal_process(job, Base.SIGKILL)
                break
            end
            sleep(0.1)
        end
        wait(process)
        lock(job[:lock]) do
            job[:process] = nothing
        end
        close(logio); logio = nothing
        if job[:action][] >= 2
            put!(job[:events], (:canceled, audio_usable(path) ? path : ""))
        elseif audio_usable(path) && (requested || success(process))
            put!(job[:events], (:transcribing, path))
            upload_worker(job, path)
        else
            put!(job[:events], (:failure, capture_error(logpath), audio_usable(path) ? path : ""))
        end
    catch
        if process !== nothing
            signal_process(job, Base.SIGKILL)
            try wait(process) catch end
            lock(job[:lock]) do
                job[:process] = nothing
            end
        end
        message = "Could not start or finish ffmpeg. Check ffmpeg, microphone permission, and disk space."
        put!(job[:events], (:failure, message, audio_usable(path) ? path : ""))
    finally
        logio === nothing || try close(logio) catch end
        isempty(logpath) || try rm(logpath; force=true) catch end
        # Only empty/incomplete capture files are discarded; usable recordings
        # remain private on disk until the text has actually been inserted.
        if !isempty(path) && !audio_usable(path)
            try rm(path; force=true) catch end
        end
    end
end

function start_capture!(menu, mic)
    job = new_job(menu.session)
    mic[:job], mic[:path], mic[:phase], mic[:note] = job, "", :starting, ""
    menu.notice = ""
    job[:task] = Threads.@spawn capture_worker(job)
end

function retry_upload!(menu, mic)
    path = mic[:path]
    if !audio_usable(path)
        mic[:phase], mic[:note] = :idle, "Saved audio is no longer available. ctrl+r mic"
        return
    end
    job = new_job(menu.session)
    mic[:job], mic[:phase], mic[:note] = job, :transcribing, ""
    menu.notice = ""
    job[:task] = Threads.@spawn upload_worker(job, path)
end

function cancel_job!(job, action=2)
    job[:action][] = action
    # Cancel can close an active socket. Do it away from the input thread.
    context = job[:context]
    Threads.@spawn try HTTP.cancel!(context) catch end
    nothing
end

function insert_transcription!(menu, text)
    input = menu.prompt
    # The existing composer is single-line; prevent terminal/control injection.
    cleaned = strip(join((iscntrl(c) ? ' ' : c for c in text)))
    isempty(cleaned) && return false
    chars = collect(cleaned)
    cursor = input.cursor
    prefix = cursor > 0 && !isspace(input.buffer[cursor]) && !isspace(first(chars)) ? " " : ""
    suffix = cursor < length(input.buffer) && !isspace(input.buffer[cursor + 1]) && !isspace(last(chars)) ? " " : ""
    inserted = collect(prefix * cleaned * suffix)
    App.save_edit!(menu.prompt_editor, input, :transcription)
    splice!(input.buffer, cursor+1:cursor, inserted)
    input.cursor += length(inserted)
    App.Tachikoma._run_validator!(input)
    true
end

function notice!(menu, kind, text)
    push!(menu.transcript, App.ChatEntry(kind=kind, text=text))
    menu.scroll = 0
end

# Tachikoma also labels a fresh legacy keypress as a repeat if its terminal
# never sent a key-release event. Kitty's raw CSI event type distinguishes a
# real repeat; for legacy input, debounce repeated bytes until a quiet gap.
function shortcut_press!(mic, event)
    event.action == App.Tachikoma.key_release && return false
    raw = App.Tachikoma.raw_capture_enabled() ? App.Tachikoma.last_event_raw() : UInt8[]
    if length(raw) >= 3 && raw[1] == 0x1b && raw[2] == UInt8('[') && raw[end] == UInt8('u')
        sequence = String(copy(raw))
        return match(r";\d+:2(?:;|u)", sequence) === nothing
    end
    now = time_ns()
    last = get(mic, :last_r_event, UInt64(0))
    mic[:last_r_event] = now
    event.action == App.Tachikoma.key_press || last == 0 || (now - last) / 1e9 > 0.75
end

function on_key!(menu, event, state)
    mic = mic_state(state)
    if event.key == :ctrl && event.char == 'r'
        shortcut_press!(mic, event) || return true
        phase = mic[:phase]
        if phase == :idle
            start_capture!(menu, mic)
        elseif phase == :failed
            retry_upload!(menu, mic)
        elseif phase in (:starting, :recording)
            mic[:job][:action][] = 1
            mic[:phase] = :stopping
            menu.notice = ""
        end
        return true
    elseif event.key == :escape && mic[:phase] in (:starting, :recording, :stopping, :transcribing, :canceling)
        if mic[:phase] != :canceling
            cancel_job!(mic[:job])
            mic[:phase] = :canceling
            menu.notice = ""
        end
        return true
    elseif event.key == :escape && mic[:phase] == :failed
        mic[:phase], mic[:note] = :idle, "Audio remains saved; ctrl+r mic"
        menu.notice = ""
        return true
    end
    if mic[:phase] == :idle && !isempty(mic[:note])
        mic[:note] = ""
    end
    false
end

function on_frame!(menu, state)
    mic = mic_state(state)
    menu.notice == "Live features reloaded." && (menu.notice = "")
    job = mic[:job]
    job === nothing && return
    events = job[:events]
    while isready(events)
        event = take!(events)
        kind = event[1]
        if kind == :recording
            mic[:path] = event[2]
            mic[:phase] == :starting && (mic[:phase] = :recording)
        elseif kind == :transcribing
            mic[:path] = event[2]
            mic[:phase] == :canceling || (mic[:phase] = :transcribing)
        elseif kind == :result
            path, text = event[2], event[3]
            if job[:action][] >= 2 || menu.session !== job[:session]
                mic[:path], mic[:phase], mic[:job] = path, :failed, nothing
                notice!(menu, :notice, "Transcription not inserted. Audio saved: $path. Ctrl+R retries upload.")
            elseif insert_transcription!(menu, text)
                mic[:phase], mic[:job], mic[:path], mic[:note] = :idle, nothing, "", "Transcription inserted · enter send · ctrl+r mic"
                Threads.@spawn try rm(path; force=true) catch end
            else
                mic[:path], mic[:phase], mic[:job] = path, :failed, nothing
                notice!(menu, :error, "Transcription was empty. Audio saved: $path. Ctrl+R retries upload.")
            end
        elseif kind == :canceled
            path = event[2]
            mic[:job], mic[:path] = nothing, path
            if isempty(path)
                mic[:phase], mic[:note] = :idle, "Microphone canceled · ctrl+r mic"
            else
                mic[:phase] = :failed
                notice!(menu, :notice, "Canceled. Audio saved: $path. Ctrl+R retries upload; Esc dismisses, then Ctrl+R records again.")
            end
        elseif kind == :failure
            message, path = event[2], event[3]
            mic[:job], mic[:path] = nothing, path
            if isempty(path)
                mic[:phase], mic[:note] = :idle, "Microphone failed · ctrl+r retry"
                notice!(menu, :error, message)
            else
                mic[:phase] = :failed
                notice!(menu, :error, message * " Audio saved: $path. Ctrl+R retries upload; Esc dismisses, then Ctrl+R records again.")
            end
        end
    end
end

function footer(menu, state)
    mic = mic_state(state)
    phase = mic[:phase]
    phase == :starting && return "Starting microphone…  ctrl+r stop  esc cancel"
    phase == :recording && return "Recording · max 10 min  ctrl+r stop  esc cancel"
    phase == :stopping && return "Stopping microphone…  esc cancel"
    phase == :transcribing && return "Transcribing…  esc cancel"
    phase == :canceling && return "Canceling…  audio will be kept"
    phase == :failed && return "Audio saved  ctrl+r retry upload  esc dismiss"
    isempty(mic[:note]) || return mic[:note]
    menu.busy ? "…  ctrl+r mic  ↑↓ scroll  ctrl+o tools" : "enter send  ctrl+r mic  ↑↓ scroll  ctrl+o tools  esc models"
end

function shutdown!(state)
    mic = get(state, :microphone, nothing)
    mic === nothing && return
    job = mic[:job]
    job === nothing && return
    cancel_job!(job, 3)
    signal_process(job, Base.SIGINT)
    task = job[:task]
    if task !== nothing
        timedwait(() -> istaskdone(task), 3.5; pollint=0.05)
        if !istaskdone(task)
            signal_process(job, Base.SIGKILL)
            timedwait(() -> istaskdone(task), 0.5; pollint=0.05)
        end
    end
    nothing
end

# Image operations use separate Responses requests and do not modify the
# session input or the persistent microphone state.
const IMAGE_CODEX_URL = "https://chatgpt.com/backend-api/codex/responses"
const IMAGE_API_URL = "https://api.openai.com/v1/responses"
const IMAGE_INPUT_LIMIT = 20 * 1024 * 1024
const IMAGE_EVENT_LIMIT = 24 * 1024 * 1024
const IMAGE_PNG_HEADER = UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
const IMAGE_PNG_END = UInt8[0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82]

struct ImageToolError <: Exception
    message::String
end

function image_path(session, value)
    value isa AbstractString && !isempty(strip(value)) || throw(ImageToolError("Supply an image path."))
    any(iscntrl, value) && throw(ImageToolError("The path contains a control character."))
    path = expanduser(String(value))
    root = session === nothing ? pwd() : session.cwd
    isabspath(path) ? normpath(path) : normpath(joinpath(root, path))
end

function image_mime(bytes)
    length(bytes) >= 8 && bytes[1:8] == IMAGE_PNG_HEADER && return "image/png"
    length(bytes) >= 3 && bytes[1:3] == UInt8[0xff, 0xd8, 0xff] && return "image/jpeg"
    if length(bytes) >= 6 && (bytes[1:6] == codeunits("GIF87a") || bytes[1:6] == codeunits("GIF89a"))
        return "image/gif"
    end
    if length(bytes) >= 12 && bytes[1:4] == codeunits("RIFF") && bytes[9:12] == codeunits("WEBP")
        return "image/webp"
    end
    throw(ImageToolError("Use a PNG, JPEG, WebP, or GIF image."))
end

# The existing HTTP-detail redactor removes known credentials. Also suppress
# data URLs and long encoded strings, which could otherwise expose an image.
function image_error_detail(response, credential)
    detail = try safe_detail(response, (credential.token, credential.account)) catch; "" end
    occursin("base64", lowercase(detail)) && return "[image data redacted]"
    detail = replace(detail, r"(?i)data:image/[^\s,;]+[^\s]*" => "[image data redacted]")
    replace(detail, r"[A-Za-z0-9+/_=-]{32,}" => "[redacted]")
end

function image_event_error(data, credential)
    response = get(data, "response", nothing)
    err = response isa AbstractDict ? get(response, "error", nothing) : nothing
    if err === nothing && response isa AbstractDict
        incomplete = get(response, "incomplete_details", nothing)
        incomplete isa AbstractDict && (err = Dict("code" => get(incomplete, "reason", "incomplete")))
    end
    err === nothing && (err = get(data, "error", data))
    selected = err isa AbstractDict ? Dict("code" => get(err, "code", nothing),
                                          "message" => get(err, "message", nothing)) : Dict()
    fake = (body=Vector{UInt8}(codeunits(JSON.json(Dict("error" => selected)))),)
    image_error_detail(fake, credential)
end

function image_stream_request(url, headers, body, callback; timeout=240)
    try
        Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
            HTTP.post(url, headers, JSON.json(body); sse_callback=callback,
                      status_exception=false, redirect=false, retry=false,
                      proxy=HTTP.ProxyConfig(), connect_timeout=15,
                      request_timeout=timeout, read_idle_timeout=180,
                      max_sse_line_bytes=IMAGE_EVENT_LIMIT, max_sse_event_bytes=IMAGE_EVENT_LIMIT)
        end
    catch
        # HTTP exceptions can contain request headers and data URLs; never show them.
        throw(ImageToolError("Could not complete the image request. Check the connection and try again."))
    end
end

function image_http_status(response, credential, label)
    response.status == 200 && return
    detail = image_error_detail(response, credential)
    throw(ImageToolError(label * " HTTP $(response.status)" * (isempty(detail) ? "" : ": " * detail)))
end

function describe_image_file(session, path, question)
    session === nothing && throw(ImageToolError("The current session model is unavailable."))
    isfile(path) || throw(ImageToolError("Image file not found or not a regular file."))
    bytes = try
        open(path, "r") do io
            read(io, IMAGE_INPUT_LIMIT + 1)
        end
    catch
        throw(ImageToolError("Could not read the image file."))
    end
    0 < length(bytes) <= IMAGE_INPUT_LIMIT || throw(ImageToolError("Image is empty or exceeds 20 MiB."))
    mime = image_mime(bytes)
    prompt = question === nothing || (question isa AbstractString && isempty(strip(question))) ?
             "Describe this image clearly and concisely." : question
    prompt isa AbstractString || throw(ImageToolError("The image question must be text or null."))
    credential = Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
        app_credentials()
    end
    credential === nothing && throw(ImageToolError("JuliaForever ChatGPT sign-in is unavailable. Sign in and retry."))
    image_url = "data:" * mime * ";base64," * App.ChatGPTAuth.Base64.base64encode(bytes)
    body = Dict("model" => session.model, "store" => false, "stream" => true,
                "instructions" => "Answer the user's question about the image.",
                "input" => [Dict("role" => "user", "content" => Any[
                    Dict("type" => "input_text", "text" => String(prompt)),
                    Dict("type" => "input_image", "image_url" => image_url)])])
    headers = ["Authorization" => "Bearer " * credential.token,
               "Content-Type" => "application/json", "Accept" => "text/event-stream"]
    chunks = IOBuffer()
    completed, failed = Ref(false), Ref("")
    callback = function(event)
        event.data == "[DONE]" && return
        data = try JSON.parse(event.data) catch; failed[] = "Invalid image response event."; return end
        data isa AbstractDict || return
        kind = get(data, "type", "")
        if kind == "response.output_text.delta"
            delta = get(data, "delta", "")
            delta isa AbstractString && write(chunks, delta)
        elseif kind == "response.completed"
            completed[] = true
            if position(chunks) == 0
                response = get(data, "response", Dict())
                for item in get(response, "output", [])
                    item isa AbstractDict || continue
                    for part in get(item, "content", [])
                        part isa AbstractDict || continue
                        get(part, "type", "") == "output_text" || continue
                        text = get(part, "text", "")
                        text isa AbstractString && write(chunks, text)
                    end
                end
            end
        elseif kind in ("response.failed", "response.incomplete", "error")
            detail = image_event_error(data, credential)
            failed[] = isempty(detail) ? "Image description response failed or was incomplete." : detail
        end
    end
    response = image_stream_request(IMAGE_API_URL, headers, body, callback)
    image_http_status(response, credential, "Image description")
    isempty(failed[]) || throw(ImageToolError("Image description failed: " * failed[]))
    completed[] || throw(ImageToolError("The image description stream ended before completion."))
    result = String(take!(chunks))
    isempty(strip(result)) && throw(ImageToolError("The model returned no image description."))
    result
end

function publish_png(path, bytes)
    parent = dirname(path)
    isdir(parent) || throw(ImageToolError("The output directory does not exist."))
    (ispath(path) || islink(path)) && throw(ImageToolError("Output already exists; choose a new path."))
    temporary, io = try mktemp(parent; cleanup=false) catch
        throw(ImageToolError("Could not create a private temporary image in the output directory."))
    end
    try
        write(io, bytes)
        close(io)
        # The link fails atomically if any file or symlink already occupies path.
        Base.Filesystem.hardlink(temporary, path)
    catch
        if ispath(path) || islink(path)
            throw(ImageToolError("Output already exists; choose a new path."))
        end
        throw(ImageToolError("Could not save the PNG without overwriting. Check directory permissions and filesystem support."))
    finally
        isopen(io) && try close(io) catch end
        try rm(temporary; force=true) catch end
    end
    nothing
end

function generate_image_file(session, path, prompt, host_model)
    lowercase(splitext(path)[2]) == ".png" || throw(ImageToolError("The output path must end in .png."))
    isdir(dirname(path)) || throw(ImageToolError("The output directory does not exist."))
    (ispath(path) || islink(path)) && throw(ImageToolError("Output already exists; choose a new path."))
    prompt isa AbstractString && !isempty(strip(prompt)) || throw(ImageToolError("Supply an image prompt."))
    (host_model === nothing || host_model isa AbstractString) || throw(ImageToolError("Host model must be text or null."))
    host = host_model === nothing || isempty(strip(host_model)) ? "gpt-6.1-sol" : String(strip(host_model))
    credential = codex_credentials()
    credential === nothing && (credential = app_credentials())
    credential === nothing && throw(ImageToolError("ChatGPT/Codex OAuth is unavailable. Sign in and retry."))
    body = Dict("model" => host, "store" => false, "stream" => true,
                "instructions" => "Generate the requested image. Do not add extra prose.",
                "input" => [Dict("role" => "user", "content" => [Dict("type" => "input_text", "text" => String(prompt))])],
                "tools" => [Dict("type" => "image_generation", "model" => "gpt-image-2", "size" => "1024x1024")],
                "tool_choice" => Dict("type" => "image_generation"))
    headers = Pair{String,String}["Authorization" => "Bearer " * credential.token,
                "originator" => "JuliaForever", "OpenAI-Beta" => "responses=experimental",
                "Accept" => "text/event-stream", "Content-Type" => "application/json",
                "User-Agent" => "juliaforever-image/1.0"]
    isempty(credential.account) || push!(headers, "ChatGPT-Account-ID" => credential.account)
    result = Ref{Union{Nothing,String}}(nothing)
    completed, failed = Ref(false), Ref("")
    function find_image(item)
        item isa AbstractDict || return
        get(item, "type", "") == "image_generation_call" || return
        value = get(item, "result", nothing)
        value isa AbstractString && !isempty(value) && (result[] = String(value))
    end
    callback = function(event)
        event.data == "[DONE]" && return
        data = try JSON.parse(event.data) catch; failed[] = "Invalid image response event."; return end
        data isa AbstractDict || return
        kind = get(data, "type", "")
        if kind == "response.output_item.done"
            find_image(get(data, "item", nothing))
        elseif kind == "response.completed"
            completed[] = true
            response = get(data, "response", Dict())
            for item in get(response, "output", [])
                find_image(item)
            end
        elseif kind in ("response.failed", "response.incomplete", "error")
            detail = image_event_error(data, credential)
            failed[] = isempty(detail) ? "Image generation response failed or was incomplete." : detail
        end
    end
    response = image_stream_request(IMAGE_CODEX_URL, headers, body, callback; timeout=300)
    image_http_status(response, credential, "Image generation")
    isempty(failed[]) || throw(ImageToolError("Image generation failed: " * failed[]))
    completed[] || throw(ImageToolError("The image generation stream ended before completion."))
    encoded = result[]
    encoded === nothing && throw(ImageToolError("The completed response contained no generated image."))
    ncodeunits(encoded) <= IMAGE_EVENT_LIMIT || throw(ImageToolError("The generated image exceeds the size limit."))
    bytes = try App.ChatGPTAuth.Base64.base64decode(encoded) catch
        throw(ImageToolError("The generated image was not valid base64."))
    end
    length(bytes) >= 20 && bytes[1:8] == IMAGE_PNG_HEADER && bytes[end-11:end] == IMAGE_PNG_END ||
        throw(ImageToolError("The completed response did not contain a complete PNG."))
    publish_png(path, bytes)
    "Saved PNG: " * path
end

function run_image_tool(session, name, args)
    try
        path = image_path(session, get(args, "path", nothing))
        if name == "describe_image"
            return describe_image_file(session, path, get(args, "question", nothing))
        end
        generate_image_file(session, path, get(args, "prompt", nothing), get(args, "host_model", nothing))
    catch e
        e isa ImageToolError ? "Error: " * e.message : "Error: Image operation failed; no sensitive request details are shown."
    end
end
