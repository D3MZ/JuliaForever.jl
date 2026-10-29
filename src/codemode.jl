"""Run Julia programs in a separate process. This is not a security sandbox."""
struct CodeMode <: Tool
    tools::Dict{String, Tool}
    timeout::Float64
    store::Dict{String, Any}
    lock::ReentrantLock
end

CodeMode(tools; timeout=300.0) = CodeMode(Dict{String, Tool}(name(tool) => tool for tool in tools if !(tool isa CodeMode)), Float64(timeout), Dict{String, Any}(), ReentrantLock())
name(::CodeMode) = "codemode"
schema(::CodeMode) = Dict("type" => "object", "properties" => Dict("code" => Dict("type" => "string")), "required" => ["code"])
function description(mode::CodeMode)
    intro = "Run Julia source in a separate process. Call tools.read((; path=\"...\")) or tools[\"name\"](args); each tool returns an object with text and iserror. ALL_TOOLS lists names, descriptions, and argument schemas. text(value) adds output; the last expression is the result. store(key, value) and load(key) keep JSON values across successful calls. The process inherits the host permissions and environment, including permitted filesystem, network, and subprocess access; it is not a security sandbox."
    specs = ["- $(name(tool)): $(description(tool)) Arguments: $(JSON3.write(schema(tool)))" for tool in sort!(collect(values(mode.tools)); by=name)]
    join([intro; specs], "\n")
end

struct CodeCancellation
    cancelled::Threads.Atomic{Bool}
    lock::ReentrantLock
    events::Set{Channel{Any}}
end
CodeCancellation(cancelled::Threads.Atomic{Bool}) = CodeCancellation(cancelled, ReentrantLock(), Set{Channel{Any}}())
CodeCancellation() = CodeCancellation(Threads.Atomic{Bool}(false))
function cancel!(cancel::CodeCancellation)
    lock(cancel.lock) do
        cancel.cancelled[] = true
        foreach(close, cancel.events)
    end
    nothing
end

struct CodeResult
    ok::Bool
    value::Any
    output::Vector{String}
    calls::Vector{NamedTuple}
    writes::Dict{String, Any}
    kind::Union{Nothing, Symbol}
    message::String
    stdout::String
    stderr::String
    pid::Int
end

function enqueue(events, event)
    try
        put!(events, event)
    catch
    end
end

invoke(::Nothing, args, name::AbstractString) = ToolFailure("Unknown tool: $name")

function invoke(tool::Tool, args, ::AbstractString)
    try
        execute(tool, args)
    catch exception
        ToolFailure(sprint(showerror, exception))
    end
end

function codefailure(cancel, timedout, started, timeout)
    cancel.cancelled[] && return (:cancelled, "Execution cancelled")
    (timedout[] || (time_ns() - started) / 1e9 >= timeout) && return (:timeout, "Execution timed out")
    nothing
end

codeimage(result::ToolResult, ::Nothing) = result
codeimage(::ToolResult, ::Image) = ToolResult("Image output is not supported by CodeMode", true)

function codeexecute(mode::CodeMode, code::AbstractString; store=Dict{String, Any}(), cancel=CodeCancellation())
    cancel.cancelled[] && return CodeResult(false, nothing, String[], NamedTuple[], Dict{String, Any}(), :cancelled, "Execution cancelled", "", "", 0)
    mktempdir() do dir
        stdoutfile = joinpath(dir, "stdout")
        stderrfile = joinpath(dir, "stderr")
        worker = joinpath(@__DIR__, "codemode_worker.jl")
        project = dirname(Base.active_project())
        cmd = `$(Base.julia_cmd()) --startup-file=no --project=$project $worker $stdoutfile $stderrfile`
        events = Channel{Any}(1024)
        lockwrite = ReentrantLock()
        done = Threads.Atomic{Bool}(false)
        timedout = Threads.Atomic{Bool}(false)
        started = time_ns()
        lock(cancel.lock) do
            cancel.cancelled[] ? close(events) : push!(cancel.events, events)
        end
        process = nothing
        reader = nothing
        writer = nothing
        timer = nothing
        alarm = nothing
        pid = 0
        output = String[]
        calls = NamedTuple[]
        result = nothing
        failure = nothing
        try
            if isfinite(mode.timeout)
                timer = Timer(max(0.0, mode.timeout - (time_ns() - started) / 1e9))
                alarm = Threads.@spawn begin
                    try
                        wait(timer)
                        timedout[] = true
                        close(events)
                    catch
                    end
                end
            end
            failure = codefailure(cancel, timedout, started, mode.timeout)
            if isnothing(failure)
                process = open(pipeline(cmd; stderr=stderrfile), "r+")
                pid = getpid(process)
                request = JSON3.write((; code=String(code), store, tools=[(; name=name(tool), description=description(tool), schema=schema(tool)) for tool in values(mode.tools)])) * "\n"
                writer = Threads.@spawn begin
                    try
                        write(process, request)
                        flush(process)
                    catch exception
                        enqueue(events, (; type="transport_error", message=sprint(showerror, exception)))
                    end
                end
                reader = Threads.@spawn begin
                    try
                        for line in eachline(process)
                            enqueue(events, JSON3.read(line))
                        end
                    catch exception
                        enqueue(events, (; type="transport_error", message=sprint(showerror, exception)))
                    end
                    enqueue(events, (; type="closed"))
                end
            end
            while isnothing(result) && isnothing(failure)
                failure = codefailure(cancel, timedout, started, mode.timeout)
                isnothing(failure) || break
                event = try
                    take!(events)
                catch
                    nothing
                end
                failure = codefailure(cancel, timedout, started, mode.timeout)
                isnothing(failure) || break
                try
                    if isnothing(event)
                        failure = (:worker, "Worker connection closed")
                    elseif event.type == "text"
                        push!(output, String(event.text))
                    elseif event.type == "call"
                        index = length(calls) + 1
                        push!(calls, (; name=String(event.name), status=:running, duration=0.0))
                        Threads.@spawn let event=event, index=index
                            callstart = time_ns()
                            tool = get(mode.tools, String(event.name), nothing)
                            answer = invoke(tool, event.args, String(event.name))
                            answer = codeimage(answer, answer.image)
                            duration = (time_ns() - callstart) / 1e9
                            enqueue(events, (; type="call_done", index, status=status(answer), duration))
                            lock(lockwrite) do
                                if !done[]
                                    try
                                        write(process, JSON3.write((; id=event.id, result=(; text=answer.text, iserror=answer.iserror))) * "\n")
                                        flush(process)
                                    catch
                                    end
                                end
                            end
                        end
                    elseif event.type == "call_done"
                        call = calls[event.index]
                        calls[event.index] = (; call.name, status=event.status, duration=event.duration)
                    elseif event.type == "result"
                        result = event
                    elseif event.type == "transport_error"
                        failure = (:worker, String(event.message))
                    elseif event.type == "closed"
                        failure = (:worker, "Worker exited without a result")
                    end
                catch exception
                    failure = (:worker, sprint(showerror, exception))
                end
                yield()
            end
        finally
            done[] = true
            lock(cancel.lock) do
                delete!(cancel.events, events)
            end
            !isnothing(timer) && close(timer)
            !isnothing(alarm) && wait(alarm)
            close(events)
            if !isnothing(process)
                if process_running(process)
                    try
                        kill(process, Base.SIGKILL)
                    catch
                    end
                end
                try
                    wait(process)
                catch
                end
                try
                    close(process)
                catch
                end
            end
            !isnothing(writer) && wait(writer)
            !isnothing(reader) && wait(reader)
        end
        for (index, call) in enumerate(calls)
            call.status == :running && (calls[index] = (; call.name, status=:unresolved, call.duration))
        end
        stdout = isfile(stdoutfile) ? read(stdoutfile, String) : ""
        stderr = isfile(stderrfile) ? read(stderrfile, String) : ""
        if !isnothing(failure)
            return CodeResult(false, nothing, output, calls, Dict{String, Any}(), failure[1], failure[2], stdout, stderr, pid)
        elseif !result.ok
            return CodeResult(false, nothing, output, calls, Dict{String, Any}(), :script, String(result.message), stdout, stderr, pid)
        end
        CodeResult(true, result.value, output, calls, Dict{String, Any}(String(key) => value for (key, value) in pairs(result.writes)), nothing, "", stdout, stderr, pid)
    end
end

function execute(mode::CodeMode, args)
    state = lock(mode.lock) do
        deepcopy(mode.store)
    end
    result = codeexecute(mode, args.code; store=state)
    if result.ok
        lock(mode.lock) do
            merge!(mode.store, result.writes)
        end
    end
    lines = copy(result.output)
    !isempty(result.stdout) && push!(lines, result.stdout)
    !isempty(result.stderr) && push!(lines, result.stderr)
    result.ok && !isnothing(result.value) && push!(lines, result.value isa AbstractString ? String(result.value) : JSON3.write(result.value))
    !result.ok && push!(lines, "$(result.kind): $(result.message)")
    ToolResult(join(lines, "\n"), !result.ok)
end
