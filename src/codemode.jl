"""Run Julia programs in a separate process. This is not a security sandbox."""
struct CodeMode <: Tool
    tools::Dict{String, Tool}
    timeout::Float64
    store::Dict{String, Any}
    lock::ReentrantLock
end

register!(tools::Dict{String, Tool}, ::CodeMode) = tools
register!(tools::Dict{String, Tool}, tool) = (tools[name(tool)] = tool; tools)
CodeMode(tools; timeout=300.0) = CodeMode(foldl(register!, tools; init=Dict{String, Tool}()), Float64(timeout), Dict{String, Any}(), ReentrantLock())
name(::CodeMode) = "codemode"
schema(::CodeMode) = Dict("type" => "object", "properties" => Dict("code" => Dict("type" => "string")), "required" => ["code"])
guidance(::CodeMode) = "Run Julia source in a separate process. Call tools.read((; path=\"...\")) or tools[\"name\"](args); each tool returns an object with text and iserror. ALL_TOOLS lists names, descriptions, and argument schemas. text(value) adds output; the last expression is the result. store(key, value) and load(key) keep JSON values across successful calls; forget!(key) deletes a key. The process inherits the host permissions and environment, including permitted filesystem, network, and subprocess access; it is not a security sandbox."
function description(mode::CodeMode)
    specs = ["- $(name(tool)): $(description(tool)) Arguments: $(JSON3.write(schema(tool)))" for tool in sort!(collect(values(mode.tools)); by=name)]
    join([guidance(mode); specs], "\n")
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

abstract type CodeResult end

struct CodeSuccess <: CodeResult
    value::Any
    output::Vector{String}
    calls::Vector{NamedTuple}
    writes::Dict{String, Any}
    deletes::Vector{String}
    kind::Union{Nothing, Symbol}
    message::String
    stdout::String
    stderr::String
    pid::Int
end

struct CodeFailure <: CodeResult
    value::Any
    output::Vector{String}
    calls::Vector{NamedTuple}
    writes::Dict{String, Any}
    deletes::Vector{String}
    kind::Union{Nothing, Symbol}
    message::String
    stdout::String
    stderr::String
    pid::Int
end

CodeSuccess(value, output, calls, writes, kind, message, stdout, stderr, pid) = CodeSuccess(value, output, calls, writes, String[], kind, message, stdout, stderr, pid)
CodeFailure(value, output, calls, writes, kind, message, stdout, stderr, pid) = CodeFailure(value, output, calls, writes, String[], kind, message, stdout, stderr, pid)
CodeResult(ok::Bool, fields...) = ok ? CodeSuccess(fields...) : CodeFailure(fields...)
CodeResult(ok, fields...) = CodeResult(convert(Bool, ok), fields...)
ok(::CodeSuccess) = true
ok(::CodeFailure) = false
Base.getproperty(result::CodeResult, name::Symbol) = name === :ok ? ok(result) : getfield(result, name)
Base.propertynames(result::CodeResult, private::Bool=false) = (:ok, fieldnames(typeof(result))...)

StructTypes.StructType(::Type{<:CodeResult}) = StructTypes.CustomStruct()
const CodeResultData = @NamedTuple{ok::Union{Nothing, Bool}, value::Any, output::Vector{String}, calls::Vector{NamedTuple}, writes::Dict{String, Any}, deletes::Union{Nothing, Vector{String}}, kind::Union{Nothing, Symbol}, message::String, stdout::String, stderr::String, pid::Int}
StructTypes.lowertype(::Type{<:CodeResult}) = CodeResultData
StructTypes.lower(result::CodeResult) = (; ok=ok(result), result.value, result.output, result.calls, result.writes, result.deletes, result.kind, result.message, result.stdout, result.stderr, result.pid)
codedeletes(::Nothing) = String[]
codedeletes(deletes::Vector{String}) = deletes

codefields(data::CodeResultData) = (data.value, data.output, data.calls, data.writes, codedeletes(data.deletes), data.kind, data.message, data.stdout, data.stderr, data.pid)

StructTypes.construct(::Type{CodeResult}, data::CodeResultData) = CodeResult(data.ok, codefields(data)...)
StructTypes.construct(::Type{CodeSuccess}, data::CodeResultData) = CodeSuccess(codefields(data)...)
StructTypes.construct(::Type{CodeFailure}, data::CodeResultData) = CodeFailure(codefields(data)...)

function enqueue(events, event)
    try
        put!(events, event)
    catch
    end
end

invoke(::Nothing, args, name::AbstractString) = ToolFailure("Unknown tool: $name")

invoke(tool::Tool, args, ::AbstractString) = execute(tool, args)

abstract type CodeEvent end
struct CodeText <: CodeEvent
    text
end
struct CodeCall <: CodeEvent
    message
end
struct CodeCallDone <: CodeEvent
    message
end
abstract type CodeReply <: CodeEvent end
struct CodeReturned <: CodeReply
    value
    writes
    deletes
end
struct CodeErrored <: CodeReply
    message
end
struct CodeTransportError <: CodeEvent
    message
end
struct CodeClosed <: CodeEvent end
struct CodeDisconnected <: CodeEvent end

const codeevents = Dict("text" => CodeText, "call" => CodeCall, "call_done" => CodeCallDone, "result" => CodeReply, "transport_error" => CodeTransportError, "closed" => CodeClosed)
codeevent(::Nothing) = CodeDisconnected()
codeevent(event::CodeEvent) = event
codeevent(event) = codeevent(get(codeevents, event.type, Nothing), event)
codeevent(::Type{Nothing}, event) = nothing
codeevent(::Type{CodeText}, event) = CodeText(event.text)
codeevent(::Type{CodeCall}, event) = CodeCall(event)
codeevent(::Type{CodeCallDone}, event) = CodeCallDone(event)
codeevent(::Type{CodeReply}, event) = codeevent((CodeErrored, CodeReturned)[Int(event.ok) + 1], event)
codeevent(::Type{CodeReturned}, event) = CodeReturned(event.value, event.writes, get(event, :deletes, String[]))
codeevent(::Type{CodeErrored}, event) = CodeErrored(event.message)
codeevent(::Type{CodeTransportError}, event) = CodeTransportError(event.message)
codeevent(::Type{CodeClosed}, event) = CodeClosed()

handlecode!(context, ::Nothing) = nothing
handlecode!(context, event::CodeText) = (push!(context.output, String(event.text)); nothing)
handlecode!(context, event::CodeReply) = event
handlecode!(context, event::CodeTransportError) = (:worker, String(event.message))
handlecode!(context, ::CodeClosed) = (:worker, "Worker exited without a result")
handlecode!(context, ::CodeDisconnected) = (:worker, "Worker connection closed")

function handlecode!(context, event::CodeCallDone)
    message = event.message
    call = context.calls[message.index]
    context.calls[message.index] = (; call.name, status=message.status, duration=message.duration)
    nothing
end

function handlecode!(context, event::CodeCall)
    message = event.message
    index = length(context.calls) + 1
    push!(context.calls, (; name=String(message.name), status=:running, duration=0.0))
    Threads.@spawn let context=context, event=message, index=index
        callstart = time_ns()
        tool = get(context.mode.tools, String(event.name), nothing)
        answer = try
            callresult = attempt(() -> invoke(tool, event.args, String(event.name)))
            codeimage(callresult, callresult.image)
        catch exception
            enqueue(context.events, CodeCallDone((; index, status=:error, duration=(time_ns() - callstart) / 1e9)))
            enqueue(context.events, CodeTransportError(sprint(showerror, exception, catch_backtrace())))
            return
        end
        duration = (time_ns() - callstart) / 1e9
        enqueue(context.events, CodeCallDone((; index, status=status(answer), duration)))
        lock(context.lockwrite) do
            if !context.done[]
                try
                    write(context.process, JSON3.write((; id=event.id, result=(; text=answer.text, iserror=answer.iserror))) * "\n")
                    flush(context.process)
                catch
                end
            end
        end
    end
    nothing
end

codeoutcome(::Nothing, result, failure) = result, failure
codeoutcome(event::CodeReply, result, failure) = event, failure
codeoutcome(value::Tuple, result, failure) = result, value

codecomplete(result, failure::Tuple, output, calls, stdout, stderr, pid) = CodeFailure(nothing, output, calls, Dict{String, Any}(), failure[1], failure[2], stdout, stderr, pid)
codecomplete(result, ::Nothing, output, calls, stdout, stderr, pid) = codecomplete(result, output, calls, stdout, stderr, pid)
codecomplete(result::CodeErrored, output, calls, stdout, stderr, pid) = CodeFailure(nothing, output, calls, Dict{String, Any}(), :script, String(result.message), stdout, stderr, pid)
codecomplete(result::CodeReturned, output, calls, stdout, stderr, pid) = CodeSuccess(result.value, output, calls, Dict{String, Any}(String(key) => value for (key, value) in pairs(result.writes)), String.(result.deletes), nothing, "", stdout, stderr, pid)

function codefailure(cancel, timedout, started, timeout)
    cancel.cancelled[] && return (:cancelled, "Execution cancelled")
    (timedout[] || (time_ns() - started) / 1e9 >= timeout) && return (:timeout, "Execution timed out")
    nothing
end

codeimage(result::ToolResult, ::Nothing) = result
codeimage(::ToolResult, ::Image) = ToolResult("Image output is not supported by CodeMode", true)

function codeexecute(mode::CodeMode, code::AbstractString; store=Dict{String, Any}(), cancel=CodeCancellation())
    cancel.cancelled[] && return CodeFailure(nothing, String[], NamedTuple[], Dict{String, Any}(), :cancelled, "Execution cancelled", "", "", 0)
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
                        enqueue(events, CodeTransportError(sprint(showerror, exception)))
                    end
                end
                reader = Threads.@spawn begin
                    try
                        for line in eachline(process)
                            enqueue(events, JSON3.read(codeunits(line)))
                        end
                    catch exception
                        enqueue(events, CodeTransportError(sprint(showerror, exception)))
                    end
                    enqueue(events, CodeClosed())
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
                    context = (; mode, output, calls, events, process, lockwrite, done)
                    result, failure = codeoutcome(handlecode!(context, codeevent(event)), result, failure)
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
        codecomplete(result, failure, output, calls, stdout, stderr, pid)
    end
end

store!(mode::CodeMode, ::CodeFailure) = nothing

function store!(mode::CodeMode, result::CodeSuccess)
    lock(mode.lock) do
        foreach(key -> delete!(mode.store, key), result.deletes)
        merge!(mode.store, result.writes)
    end
    nothing
end

present!(lines::Vector{String}, ::Nothing) = nothing
present!(lines::Vector{String}, value::AbstractString) = push!(lines, String(value))
present!(lines::Vector{String}, value) = push!(lines, JSON3.write(value))
render!(lines::Vector{String}, result::CodeSuccess) = present!(lines, result.value)
render!(lines::Vector{String}, result::CodeFailure) = push!(lines, "$(result.kind): $(result.message)")
toolresult(::CodeSuccess, lines) = ToolSuccess(join(lines, "\n"))
toolresult(::CodeFailure, lines) = ToolFailure(join(lines, "\n"))

function execute(mode::CodeMode, args)
    state = lock(mode.lock) do
        deepcopy(mode.store)
    end
    result = codeexecute(mode, args.code; store=state)
    store!(mode, result)
    lines = copy(result.output)
    !isempty(result.stdout) && push!(lines, result.stdout)
    !isempty(result.stderr) && push!(lines, result.stderr)
    render!(lines, result)
    toolresult(result, lines)
end
