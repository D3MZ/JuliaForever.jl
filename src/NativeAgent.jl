module NativeAgent

using Dates
using HTTP
using JSON
using UUIDs
import ..ChatGPTAuth
import ..HotReload

const API = "https://api.openai.com/v1"
const DEFAULT_WINDOW = 272_000
const TOOL_OUTPUT_CHARS = 24_000
const COMMAND_OUTPUT_BYTES = 100_000

struct ProviderError <: Exception
    message::String
end

struct Cancelled <: Exception end

mutable struct TurnControl
    lock::ReentrantLock
    cancelled::Threads.Atomic{Bool}
    context::Union{Nothing,HTTP.RequestContext}
    process::Union{Nothing,Base.Process}
    steering::Vector{String}
    followups::Vector{String}
    accepting::Bool
end
TurnControl() = TurnControl(ReentrantLock(), Threads.Atomic{Bool}(false), nothing, nothing, String[], String[], true)

function cancel!(control::TurnControl)
    control.cancelled[] = true
    context, process = lock(control.lock) do
        control.accepting = false
        (control.context, control.process)
    end
    context === nothing || try HTTP.cancel!(context) catch end
    if process !== nothing
        # Commands run in their own session; terminate their children as well.
        try ccall(:kill, Cint, (Cint, Cint), -getpid(process), Base.SIGTERM) catch end
        try kill(process, Base.SIGTERM) catch end
    end
end

function enqueue!(control::TurnControl, prompt::String, mode::Symbol)
    lock(control.lock) do
        (control.accepting && !control.cancelled[]) || return false
        push!(mode == :steer ? control.steering : control.followups, prompt)
        true
    end
end

function take_steering!(control::TurnControl)
    lock(control.lock) do
        prompts = copy(control.steering)
        empty!(control.steering)
        prompts
    end
end

function next_pending!(control::TurnControl)
    lock(control.lock) do
        if !isempty(control.steering)
            prompts = copy(control.steering)
            empty!(control.steering)
            return prompts
        elseif !isempty(control.followups)
            return [popfirst!(control.followups)]
        end
        control.accepting = false
        String[]
    end
end

function response_error(response)
    detail = try
        data = JSON.parse(String(copy(response.body)))
        error = get(data, "error", nothing)
        error isa AbstractDict ? string(get(error, "code", ""), " ", get(error, "message", "")) :
                                string(get(data, "detail", ""))
    catch
        ""
    end
    request_id = HTTP.header(response, "x-request-id", "")
    suffix = isempty(request_id) ? "" : " [request $request_id]"
    ProviderError("OpenAI HTTP $(response.status): $(strip(detail))$suffix")
end

function models()
    token = ChatGPTAuth.access_token()
    response = HTTP.get(API * "/models", ["Authorization" => "Bearer " * token];
                        status_exception=false, redirect=false, retry=false, request_timeout=30)
    response.status == 200 || throw(response_error(response))
    body = JSON.parse(String(response.body))
    result = NamedTuple{(:id, :name, :window),Tuple{String,String,Int}}[]
    for item in get(body, "models", [])
        get(item, "visibility", "") == "list" || continue
        slug = get(item, "slug", nothing)
        slug isa AbstractString && !isempty(slug) || continue
        name = get(item, "display_name", slug)
        window = get(item, "context_window", DEFAULT_WINDOW)
        window isa Integer && window > 0 || (window = DEFAULT_WINDOW)
        push!(result, (id=String(slug), name=String(name), window=Int(window)))
    end
    isempty(result) && throw(ProviderError("The account returned no selectable models."))
    result
end

function tool(name, description, properties, required)
    Dict("type" => "function", "name" => name, "description" => description, "strict" => true,
         "parameters" => Dict("type" => "object", "properties" => properties,
                              "required" => required, "additionalProperties" => false))
end

const STRING = Dict("type" => "string")
const INTEGER = Dict("type" => "integer")
const TOOLS = [Dict("type" => "namespace", "name" => "local", "description" => "Work with local files and commands.",
    "tools" => [
        tool("list", "List a directory. Paths may be relative to the working directory.",
             Dict("path" => STRING), ["path"]),
        tool("search", "Search files recursively for a literal string. Returns matching lines.",
             Dict("path" => STRING, "query" => STRING, "limit" => INTEGER), ["path", "query", "limit"]),
        tool("read", "Read UTF-8 text, starting at the 1-based line offset, for at most limit lines.",
             Dict("path" => STRING, "offset" => INTEGER, "limit" => INTEGER), ["path", "offset", "limit"]),
        tool("write", "Create or overwrite a UTF-8 file with the given content.",
             Dict("path" => STRING, "content" => STRING), ["path", "content"]),
        tool("edit", "Replace one unique exact occurrence of old_text with new_text in a file.",
             Dict("path" => STRING, "old_text" => STRING, "new_text" => STRING), ["path", "old_text", "new_text"]),
        tool("command", "Run a shell command in the working directory; return its output and exit status.",
             Dict("command" => STRING), ["command"]),
    ])]

mutable struct Session
    model::String
    window::Int
    cwd::String
    path::String
    paths::Vector{String}
    parent::Union{Nothing,String}
    input::Vector{Any}
    tokens::Int
    remember::Bool
end

function timestamp()
    string(Dates.now(Dates.UTC)) * "Z"
end

function append_entry!(session::Session, kind::String, data)
    id = string(uuid4())
    entry = Dict("id" => id, "parentId" => session.parent, "type" => kind,
                 "timestamp" => timestamp(), "data" => data)
    open(session.path, "a") do io
        write(io, JSON.json(entry), '\n')
    end
    session.parent = id
end

function resume_file()
    profile = get(ENV, "JULIAFOREVER_PROFILE", "")
    isempty(profile) ? "resume.json" : "resume-" * basename(normpath(profile)) * ".json"
end

function remember_session!(session::Session)
    session.remember || return
    ChatGPTAuth.save_json(resume_file(), Dict("path" => session.path, "window" => session.window))
end

function new_log(cwd, model, previous, window; remember=true)
    dir = joinpath(ChatGPTAuth.ensure_dir(), "sessions")
    mkpath(dir; mode=0o700)
    chmod(dir, 0o700)
    path = joinpath(dir, string(uuid4()) * ".jsonl")
    open(path, "w") do io end
    chmod(path, 0o600)
    session = Session(model, window, cwd, path, copy(previous), nothing, Any[], 0, remember)
    append_entry!(session, "session", Dict("version" => 1, "cwd" => cwd, "model" => model,
                                          "window" => window, "previousSessions" => previous))
    session
end

function Session(model::String, window::Int, cwd::String; remember=true)
    session = new_log(abspath(cwd), model, String[], min(DEFAULT_WINDOW, window); remember=remember)
    remember_session!(session)
    session
end

function restore_session()
    saved = ChatGPTAuth.read_json(resume_file())
    saved === nothing && return nothing
    path = get(saved, "path", "")
    path isa AbstractString && isfile(path) || return nothing
    try
        entries = open(path) do io
            [JSON.parse(line) for line in eachline(io) if !isempty(line)]
        end
        isempty(entries) && return nothing
        header = entries[1]["data"]
        session = Session(String(header["model"]), Int(get(header, "window", DEFAULT_WINDOW)),
                          String(header["cwd"]), String(path), String.(get(header, "previousSessions", [])),
                          nothing, Any[], 0, true)
        pending = Dict{String,Any}()
        for entry in entries
            session.parent = String(entry["id"])
            kind, data = entry["type"], entry["data"]
            if kind in ("message", "tool_result")
                push!(session.input, data)
                if get(data, "type", "") == "function_call"
                    pending[String(data["call_id"])] = data
                elseif get(data, "type", "") == "function_call_output"
                    delete!(pending, String(data["call_id"]))
                end
            elseif kind == "usage"
                session.tokens = Int(get(data, "estimated_context_tokens",
                                         Int(get(data, "input_tokens", 0)) + Int(get(data, "output_tokens", 0))))
            end
        end
        for call_id in keys(pending)
            item = Dict("type" => "function_call_output", "call_id" => call_id,
                        "output" => "Tool execution was interrupted by a restart.")
            push!(session.input, item)
            append_entry!(session, "tool_result", item)
        end
        session
    catch
        nothing
    end
end

function rollover!(session::Session)
    previous = [session.paths; session.path]
    next = new_log(session.cwd, session.model, previous, session.window; remember=session.remember)
    session.path, session.paths, session.parent = next.path, next.paths, next.parent
    empty!(session.input)
    session.tokens = 0
    item = Dict("role" => "user", "content" => "Use your read tool to read prior session logs and continue the work. Paths: " * JSON.json(previous))
    push!(session.input, item)
    append_entry!(session, "message", item)
    remember_session!(session)
end

function path_in(session::Session, path::AbstractString)
    isabspath(path) ? normpath(path) : normpath(joinpath(session.cwd, path))
end

function limit_output(text::AbstractString)
    length(text) <= TOOL_OUTPUT_CHARS && return String(text)
    first(text, TOOL_OUTPUT_CHARS) * "\n[Output truncated; request a smaller range.]"
end

function command_output(path::String)
    bytes, truncated = open(path, "r") do io
        data = read(io, COMMAND_OUTPUT_BYTES + 1)
        (data[1:min(end, COMMAND_OUTPUT_BYTES)], length(data) > COMMAND_OUTPUT_BYTES)
    end
    text = String(copy(bytes))
    if !isvalid(text)
        # A byte limit can split the final UTF-8 codepoint.
        for trim in 1:min(3, length(bytes))
            candidate = String(bytes[1:end-trim])
            if isvalid(candidate)
                text = candidate
                break
            end
        end
    end
    isvalid(text) || return "[Non-UTF-8 command output omitted.]"
    limit_output(text) * (truncated ? "\n[Command output truncated.]" : "")
end

function run_tool(session::Session, name::AbstractString, args, control::TurnControl=TurnControl())
    if name == "list"
        dir = path_in(session, args["path"])
        return join([entry * (isdir(joinpath(dir, entry)) ? "/" : "") for entry in readdir(dir)], '\n')
    elseif name == "read"
        path = path_in(session, args["path"])
        offset = max(1, Int(args["offset"]))
        limit = max(1, Int(args["limit"]))
        lines = String[]
        characters = 0
        open(path) do io
            for (i, line) in enumerate(eachline(io))
                i < offset && continue
                i >= offset + limit && break
                remaining = max(0, TOOL_OUTPUT_CHARS - characters)
                remaining == 0 && break
                part = length(line) > remaining ? first(line, remaining) * " [line truncated]" : line
                push!(lines, "$i: $part")
                characters += length(part)
                characters >= TOOL_OUTPUT_CHARS && break
            end
        end
        return isempty(lines) ? "(no lines)" : limit_output(join(lines, '\n'))
    elseif name == "search"
        path = path_in(session, args["path"])
        query, limit = String(args["query"]), max(1, Int(args["limit"]))
        found = String[]
        files = isfile(path) ? [path] : (joinpath(root, name) for (root, _, names) in walkdir(path) for name in names)
        for file in files
            try
                open(file) do io
                    for (number, line) in enumerate(eachline(io))
                        occursin(query, line) && push!(found, "$file:$number:$line")
                        length(found) >= limit && break
                    end
                end
            catch
                continue
            end
            length(found) >= limit && break
        end
        isempty(found) && return "(no matches)"
        return join(found, '\n') * (length(found) >= limit ? "\n(results limited)" : "")
    elseif name == "write"
        path = path_in(session, args["path"])
        mkpath(dirname(path))
        write(path, String(args["content"]))
        return "Wrote $path"
    elseif name == "edit"
        path = path_in(session, args["path"])
        old, new = String(args["old_text"]), String(args["new_text"])
        isempty(old) && return "Error: old_text must not be empty."
        content = read(path, String)
        matches = findall(old, content)
        length(matches) == 1 || return "Error: old_text matched $(length(matches)) times."
        write(path, replace(content, old => new; count=1))
        return "Edited $path"
    elseif name == "command"
        control.cancelled[] && throw(Cancelled())
        path, output = mktemp()
        process = nothing
        try
            command = Cmd(Cmd(["/bin/sh", "-c", String(args["command"])]); dir=session.cwd, detach=true)
            lock(control.lock) do
                control.cancelled[] && throw(Cancelled())
                process = run(pipeline(ignorestatus(command); stdin=devnull, stdout=output, stderr=output); wait=false)
                control.process = process
            end
            wait(process)
            flush(output)
            control.cancelled[] && throw(Cancelled())
            return command_output(path) * "\nExit status: $(process.exitcode)"
        finally
            lock(control.lock) do
                control.process === process && (control.process = nothing)
            end
            close(output)
            rm(path; force=true)
        end
    end
    "Unknown tool: $name"
end

function inference(session::Session, emit::Function, generation, control::TurnControl)
    control.cancelled[] && throw(Cancelled())
    token = ChatGPTAuth.access_token()
    instructions = if !session.remember
        "You are a Julia-native feature builder. Work in $(session.cwd). Follow the user's feature contract " *
        "and use local tools to write the requested artifact. Avoid unrelated repository discovery and " *
        "large tool output; do not inspect session logs unless continuing after a context rollover."
    else
        "You are a Julia-native local coding agent. Work in $(session.cwd). " *
        "Use the local tools to inspect and change files and run commands. " *
        "Read relevant AGENTS.md and skill instructions when applicable. " *
        "Live Julia feature modules can be changed or added without restarting; " *
        "see src/HotReload.jl and src/LiveFeatures.jl for the hook interface. " *
        (isempty(get(ENV, "JULIAFOREVER_PROFILE", "")) ?
         "The live feature module is src/LiveFeatures.jl. " :
         "The active live feature directory is $(joinpath(ENV["JULIAFOREVER_PROFILE"], "features")). ") *
        "Changes to the core runtime, existing types, or other files require a restart."
    end
    body = Dict("model" => session.model, "instructions" => instructions, "input" => session.input,
                "tools" => Any[TOOLS...; HotReload.tool_schemas(generation)...], "store" => false, "stream" => true,
                "include" => ["reasoning.encrypted_content"])
    session.model == "gpt-6.1-terra" && (body["reasoning"] = Dict("effort" => "max"))
    complete = Ref{Any}(nothing)
    failed = Ref{Any}(nothing)
    streamed_items = Any[]
    callback = function(event)
        event.data == "[DONE]" && return
        data = JSON.parse(event.data)
        type = get(data, "type", "")
        if type == "response.output_text.delta"
            emit(:delta, String(get(data, "delta", "")))
        elseif type == "response.output_item.done"
            push!(streamed_items, data["item"])
        elseif type == "response.completed"
            complete[] = data["response"]
        elseif type in ("response.failed", "response.incomplete", "error")
            failed[] = data
        end
    end
    context = HTTP.RequestContext()
    lock(control.lock) do
        control.cancelled[] && throw(Cancelled())
        control.context = context
    end
    # Give each stream its own connection pool so cancelling one builder does
    # not close another builder's connection.
    client = HTTP.Client(; prefer_http2=false, cookiejar=nothing)
    response = try
        HTTP.post(API * "/responses", ["Authorization" => "Bearer " * token,
                                      "Content-Type" => "application/json", "Accept" => "text/event-stream"],
                  JSON.json(body); client=client, sse_callback=callback, status_exception=false, redirect=false,
                  retry=false, protocol=:h1, request_timeout=session.remember ? 0 : 300,
                  read_idle_timeout=120, context=context)
    catch
        control.cancelled[] && throw(Cancelled())
        rethrow()
    finally
        lock(control.lock) do
            control.context === context && (control.context = nothing)
        end
        try close(client) catch end
    end
    control.cancelled[] && throw(Cancelled())
    response.status == 200 || throw(response_error(response))
    failed[] === nothing || throw(ProviderError("Response failed: " * JSON.json(failed[])))
    complete[] === nothing && throw(ProviderError("The response stream ended before completion."))
    isempty(get(complete[], "output", [])) && (complete[]["output"] = streamed_items)
    complete[]
end

function add_user!(session::Session, prompt::String)
    item = Dict("role" => "user", "content" => prompt)
    push!(session.input, item)
    append_entry!(session, "message", item)
end

function run_turn!(session::Session, prompt::String, emit::Function;
                   control::TurnControl=TurnControl(), live::Bool=true)
    add_user!(session, prompt)
    overflow_recovered = false
    while true
        control.cancelled[] && throw(Cancelled())
        generation = live ? HotReload.snapshot() : nothing
        result = try
            inference(session, emit, generation, control)
        catch error
            if error isa ProviderError && occursin("context_length_exceeded", error.message) && !overflow_recovered
                rollover!(session)
                emit(:rollover, "Continuing in a new session using the previous session logs.")
                overflow_recovered = true
                continue
            end
            rethrow()
        end
        usage = get(result, "usage", Dict())
        session.tokens = Int(get(usage, "input_tokens", 0)) + Int(get(usage, "output_tokens", 0))
        output = get(result, "output", [])
        for entry in output
            push!(session.input, entry)
            append_entry!(session, "message", entry)
        end
        calls = filter(x -> get(x, "type", "") == "function_call", output)
        steering = take_steering!(control)
        for call in calls
            control.cancelled[] && throw(Cancelled())
            name = String(call["name"])
            emit(:tool, call)
            yield()
            output_text = if !isempty(steering)
                "Skipped because the user steered the agent."
            else
                try
                    args = JSON.parse(String(call["arguments"]))
                    HotReload.has_tool(generation, name) ?
                        string(HotReload.run_tool(generation, session, name, args)) : run_tool(session, name, args, control)
                catch error
                    error isa Cancelled && rethrow()
                    "Error: " * sprint(showerror, error)
                end
            end
            output_text = limit_output(output_text)
            result_item = Dict("type" => "function_call_output", "call_id" => call["call_id"], "output" => output_text)
            push!(session.input, result_item)
            append_entry!(session, "tool_result", result_item)
            emit(:tool_result, result_item)
            session.tokens += cld(ncodeunits(output_text), 2)
            append!(steering, take_steering!(control))
        end
        usage_record = Dict{String,Any}(k => usage[k] for k in ("input_tokens", "output_tokens", "total_tokens") if haskey(usage, k))
        usage_record["estimated_context_tokens"] = session.tokens
        append_entry!(session, "usage", usage_record)
        threshold = max(1, session.window - min(16_384, max(2_048, session.window ÷ 8)))
        rolled = session.tokens >= threshold
        if rolled
            rollover!(session)
            emit(:rollover, "Continuing in a new session using the previous session logs.")
        end
        if !isempty(steering)
            foreach(p -> add_user!(session, p), steering)
            continue
        end
        rolled && continue
        if isempty(calls)
            pending = next_pending!(control)
            isempty(pending) && return
            emit(:boundary, "")
            foreach(p -> add_user!(session, p), pending)
        end
    end
end

end
