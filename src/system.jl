struct Bash <: Tool
    cwd::String
end

struct PowerShell <: Tool
    cwd::String
end

struct Ls <: Tool
    cwd::String
end

export ShellCancellation, ShellUpdate

"""
    ShellUpdate

`execute(shell, args; on_update)` calls `on_update` with an initial empty update and cumulative output snapshots. Snapshots retain the last 2,000 lines or 50 KiB; `file` identifies the preserved full-output file when truncated.
"""
struct ShellUpdate
    text::String
    file::Union{Nothing, String}
end

abstract type ShellOutcome end
struct ShellComplete <: ShellOutcome end
struct ShellTimeout <: ShellOutcome end
struct ShellCancelled <: ShellOutcome end
struct ShellStopFailed <: ShellOutcome end
struct Signalled end

struct WindowsJob
    handle::Ptr{Cvoid}
    started::UInt64
end
WindowsJob(handle::Ptr{Cvoid}) = WindowsJob(handle, time_ns())

struct ShellTail
    text::String
    notice::String
    file::Union{Nothing, String}
end

struct ShellReport
    tail::ShellTail
    file::Union{Nothing, String}
    outcome::Union{ShellComplete, ShellTimeout, ShellCancelled, ShellStopFailed}
    exitcode::Union{Nothing, Int}
end

abstract type ShellEscape end
struct ShellText <: ShellEscape end
struct ShellEsc <: ShellEscape end
struct ShellCSI <: ShellEscape end
struct ShellOSC <: ShellEscape end
struct ShellOSCEsc <: ShellEscape end
abstract type ShellChunkEnd end
struct ShellMore <: ShellChunkEnd end
struct ShellFinal <: ShellChunkEnd end

mutable struct ShellChunks{F}
    callback::F
    offset::Int
    pending::Vector{UInt8}
    escape::Union{ShellText, ShellEsc, ShellCSI, ShellOSC, ShellOSCEsc}
    file::String
    io::IOStream
    report::Union{Nothing, ShellReport}
end

function ShellChunks(callback)
    file, io = mktemp(; cleanup=false)
    ShellChunks(callback, 0, UInt8[], ShellText(), file, io, nothing)
end
(chunks::ShellChunks)(::ShellUpdate) = nothing

function closechunks!(chunks::ShellChunks)
    close(chunks.io)
    keepchunks!(chunks.file, chunks.report)
    nothing
end
keepchunks!(file, ::Nothing) = rm(file; force=true)
keepchunks!(file, report::ShellReport) = removeoutput(file, report.file)

mutable struct ShellRun
    process::Base.Process
    job::Union{Nothing, WindowsJob}
    lock::ReentrantLock
    outcome::Union{Nothing, ShellOutcome}
    done::Channel{ShellOutcome}
end

ShellRun(process::Base.Process, job=nothing) = ShellRun(process, job, ReentrantLock(), nothing, Channel{ShellOutcome}(1))

mutable struct ShellCancellation
    lock::ReentrantLock
    runs::Union{Nothing, Set{ShellRun}}
end

ShellCancellation() = ShellCancellation(ReentrantLock(), Set{ShellRun}())

cancel!(::Nothing) = nothing
cancelruns!(::Nothing) = nothing
cancelruns!(runs::Set{ShellRun}) = foreach(run -> signal!(run, ShellCancelled()), runs)

function cancel!(cancel::ShellCancellation)
    lock(cancel.lock) do
        runs = cancel.runs
        cancel.runs = nothing
        cancelruns!(runs)
    end
    nothing
end

name(::Bash) = "bash"
name(::PowerShell) = "powershell"
name(::Ls) = "ls"

schema(::Union{Bash, PowerShell}) = Dict("type" => "object", "properties" => Dict("command" => Dict("type" => "string"), "timeout" => Dict("type" => "number")), "required" => ["command"])
schema(::Ls) = Dict("type" => "object", "properties" => Dict("path" => Dict("type" => "string"), "limit" => Dict("type" => "number")))

description(::Bash) = "Execute a bash command, returning combined stdout and stderr. Output is limited to the last 2000 lines or 50KB; the full output is saved when truncated. Timeout is in seconds."
description(::PowerShell) = "Execute a PowerShell command, returning combined stdout and stderr. Output is limited to the last 2000 lines or 50KB; the full output is saved when truncated. Timeout is in seconds."
description(::Ls) = "List directory entries, including dotfiles and directories marked with /."

fallback(value, next) = value
fallback(::Nothing, next) = next()
filecandidate(path) = isfile(path) ? path : nothing
shellconfig(::Nothing, args) = nothing
shellconfig(executable::AbstractString, args) = (executable, args)

function config(::Bash)
    if Sys.iswindows()
        for base in (get(ENV, "ProgramFiles", ""), get(ENV, "ProgramFiles(x86)", ""))
            candidate = joinpath(base, "Git", "bin", "bash.exe")
            !isempty(base) && isfile(candidate) && return (candidate, ["-c"])
        end
        return shellconfig(Sys.which("bash.exe"), ["-c"])
    end
    executable = isfile("/bin/bash") ? "/bin/bash" : something(Sys.which("bash"), "sh")
    (executable, ["-c"])
end

function config(::PowerShell)
    Sys.iswindows() || return nothing
    executable = fallback(Sys.which("pwsh.exe"), () -> filecandidate(joinpath(get(ENV, "ProgramFiles", ""), "PowerShell", "7", "pwsh.exe")))
    executable = fallback(executable, () -> Sys.which("powershell.exe"))
    executable = fallback(executable, () -> filecandidate(joinpath(get(ENV, "SystemRoot", ""), "System32", "WindowsPowerShell", "v1.0", "powershell.exe")))
    shellconfig(executable, ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command"])
end

shellname(::Bash) = "bash"
shellname(::PowerShell) = "PowerShell"
shellcommand(::Bash, command) = command
shellcommand(::PowerShell, command) = "try { [Console]::OutputEncoding=[System.Text.Encoding]::UTF8 } catch {}\n" * command

function stop(process::Base.Process)
    # Keep Julia's process handle locked until signalling finishes, so its PID cannot be reaped and reused in between.
    Base.iolock_begin()
    try
        process_exited(process) && return ShellComplete()
        pid = ccall(:jl_uv_process_pid, Cint, (Ptr{Cvoid},), process.handle)
        ccall(:kill, Cint, (Cint, Cint), -pid, Base.SIGKILL) == 0 && return Signalled()
        Base.Libc.errno() == Base.Libc.ESRCH ? ShellComplete() : ShellStopFailed()
    finally
        Base.iolock_end()
    end
end

function stop(process::Base.Process, job, requested::Union{ShellTimeout, ShellCancelled})
    result = stop(process, job)
    stop(requested, result)
end
stop(process::Base.Process, ::Nothing) = Sys.iswindows() ? ShellStopFailed() : stop(process)
stop(process::Base.Process, job, ::ShellComplete) = ShellComplete()

stop(requested::ShellOutcome, ::Signalled) = requested
stop(requested::ShellOutcome, result::Union{ShellComplete, ShellStopFailed}) = result

function signal!(run::ShellRun, outcome::ShellOutcome)
    lock(run.lock) do
        signal!(run, outcome, run.outcome)
    end
end

signal!(run::ShellRun, outcome::ShellOutcome, previous::ShellOutcome) = nothing

function signal!(run::ShellRun, outcome::ShellOutcome, ::Nothing)
    result = stop(run.process, run.job, outcome)
    run.outcome = result
    put!(run.done, result)
    nothing
end

cancellation(::Nothing) = ShellCancellation()
cancellation(cancel::ShellCancellation) = cancel
deadline(run::ShellRun, ::Nothing) = nothing
duration(::Nothing, timeout) = timeout
duration(job::WindowsJob, timeout) = max(0.0, timeout - (time_ns() - job.started) / 1e9)
deadline(run::ShellRun, timeout::Real) = Timer(_ -> signal!(run, ShellTimeout()), duration(run.job, timeout))
waitfor(::Nothing, outcome::ShellOutcome) = nothing
waitfor(task::Task, ::ShellStopFailed) = nothing
waitfor(task::Task, outcome::ShellOutcome) = wait(task)
cleanup!(::Nothing) = nothing
cleanup!(timer::Timer) = close(timer)
removerun!(::Nothing, run) = nothing
removerun!(runs::Set{ShellRun}, run) = delete!(runs, run)

function cleanup!(token::ShellCancellation, run::ShellRun, watcher)
    lock(token.lock) do
        removerun!(token.runs, run)
    end
    signal!(run, ShellCancelled())
    waitfor(watcher, run.outcome)
    nothing
end

shellfailure(output, status) = ToolFailure(isempty(output) ? status : "$output\n\n$status")
shellresult(::ShellTimeout, output, timeout, process) = shellfailure(output, "Command timed out after $timeout seconds")
shellresult(::ShellCancelled, output, timeout, process) = shellfailure(output, "Command aborted")
shellresult(::ShellStopFailed, output, timeout, process) = shellfailure(output, "Could not stop shell process group; the command may still be running")

function shellresult(::ShellComplete, output, timeout, process)
    isempty(output) && (output = "(no output)")
    code = process.termsignal == 0 ? process.exitcode : 128 + process.termsignal
    code != 0 && return ToolFailure("$output\n\nCommand exited with code $code")
    ToolResult(output)
end

mutable struct ShellMeasure
    bytes::Int
    newlines::Int
    lastline::Int
    completed::Int
    lastbyte::UInt8
end

ShellMeasure() = ShellMeasure(0, 0, 0, 0, 0x00)

function measure!(measure::ShellMeasure, io, size)
    seek(io, measure.bytes)
    while measure.bytes < size
        block = read(io, min(65536, size - measure.bytes))
        measure.bytes += length(block)
        for byte in block
            measure.lastbyte = byte
            if byte == 0x0a
                measure.newlines += 1
                measure.completed = measure.lastline
                measure.lastline = 0
            else
                measure.lastline += 1
            end
        end
    end
    lines = measure.newlines + (measure.bytes > 0 && measure.lastbyte != 0x0a)
    (measure.bytes, lines, measure.lastbyte == 0x0a ? measure.completed : measure.lastline)
end

measure(io) = measure!(ShellMeasure(), io, filesize(io))

function sizeformat(bytes)
    bytes < 1024 && return "$(bytes)B"
    bytes < 1024 * 1024 && return "$(round(bytes / 1024; digits=1))KB"
    "$(round(bytes / (1024 * 1024); digits=1))MB"
end

struct ShellLines
    lines::Vector{SubString{String}}
end
struct ShellBytes
    lines::Vector{SubString{String}}
end
struct ShellFragment
    line::SubString{String}
end

function selecttail(pieces)
    selected = SubString{String}[]
    used = 0
    for piece in Iterators.reverse(pieces)
        length(selected) == 2000 && return ShellLines(selected)
        needed = ncodeunits(piece) + !isempty(selected)
        used + needed > 51200 && return tailoverflow(selected, piece)
        pushfirst!(selected, piece)
        used += needed
    end
    ShellLines(selected)
end

function tailoverflow(selected, piece)
    isempty(selected) || return ShellBytes(selected)
    raw = collect(codeunits(piece))
    start = max(1, length(raw) - 51200 + 1)
    while start <= length(raw) && raw[start] & 0xc0 == 0x80
        start += 1
    end
    ShellFragment(SubString(String(raw[start:end])))
end

tailstart(selection::ShellFragment, pieces, offset, preceding) = selection
function tailstart(selection::Union{ShellLines, ShellBytes}, pieces, offset, preceding)
    if offset > 0 && preceding != 0x0a && length(selection.lines) == length(pieces)
        popfirst!(selection.lines)
        return ShellBytes(selection.lines)
    end
    selection
end
tailtext(selection::Union{ShellLines, ShellBytes}) = join(selection.lines, '\n')
tailtext(selection::ShellFragment) = String(selection.line)
tailnotice(selection::ShellFragment, output, lines, lastsize, file) = "Showing last $(sizeformat(ncodeunits(output))) of line $lines (line is $(sizeformat(lastsize))). Full output: $file"
tailnotice(selection::ShellLines, output, lines, lastsize, file) = tailnotice(selection.lines, lines, "", file)
tailnotice(selection::ShellBytes, output, lines, lastsize, file) = tailnotice(selection.lines, lines, length(selection.lines) < 2000 ? " (50.0KB limit)" : "", file)
tailnotice(selected, lines, limit, file) = "Showing lines $(lines - length(selected) + 1)-$lines of $lines$limit. Full output: $file"

function tail(io, file, bytes, lines, lastsize)
    if bytes <= 51200 && lines <= 2000
        seekstart(io)
        return ShellTail(String(read(io, bytes)), "", nothing)
    end
    offset = max(0, bytes - 51201)
    preceding = offset > 0 ? (seek(io, offset - 1); read(io, UInt8)) : 0x0a
    seek(io, offset)
    data = read(io, bytes - offset)
    !isempty(data) && last(data) == 0x0a && pop!(data)
    pieces = split(String(data), '\n'; keepempty=true)
    selection = tailstart(selecttail(pieces), pieces, offset, preceding)
    output = tailtext(selection)
    notice = tailnotice(selection, output, lines, lastsize, file)
    ShellTail(output, "\n\n[$notice]", file)
end

remember!(saved, ::Nothing) = nothing
remember!(saved, file::String) = (saved[] = file)
removeoutput(file, ::Nothing) = rm(file; force=true)
removeoutput(file, ::String) = nothing
cleanupoutput(file, ::Nothing, saved) = removeoutput(file, saved)
cleanupoutput(file, ::String, saved) = nothing

function tail(io, file)
    result = tail(io, file, measure(io)...)
    result = bound(result, file, shelltext(result.text))
    (result.text * result.notice, result.file)
end

update(::Nothing, value) = nothing
update(callback::F, value) where {F} = callback(value)

function shelltext(text::AbstractString)
    isvalid(text) && return String(text)
    join((isvalid(char) ? char : '\ufffd' for char in text))
end

function live(text::String)
    isempty(text) && return text
    index = lastindex(text)
    isvalid(text[index]) && return shelltext(text)
    byte = codeunit(text, index)
    width = 0xc2 <= byte <= 0xdf ? 2 : 0xe0 <= byte <= 0xef ? 3 : 0xf0 <= byte <= 0xf4 ? 4 : 0
    ending = collect(codeunits(text)[index:end])
    if 0 < length(ending) < width
        length(ending) == 1 && push!(ending, byte == 0xe0 ? 0xa0 : byte == 0xf0 ? 0x90 : 0x80)
        append!(ending, fill(0x80, width - length(ending)))
        isvalid(String(ending)) && return shelltext(SubString(text, 1, prevind(text, index)))
    end
    shelltext(text)
end

notice(snapshot::ShellTail, limited::ShellTail, ::Nothing) = limited.notice
notice(snapshot::ShellTail, limited::ShellTail, file::String) = "\n\n[Showing last $(sizeformat(ncodeunits(limited.text))) after decoding. Full output: $file]"

function bound(snapshot::ShellTail, file, text::String)
    ncodeunits(text) <= 51200 && return ShellTail(text, snapshot.notice, snapshot.file)
    io = IOBuffer(text)
    limited = tail(io, file, measure!(ShellMeasure(), io, ncodeunits(text))...)
    ShellTail(limited.text, notice(snapshot, limited, snapshot.file), file)
end

function shellupdate!(callback::F, snapshot::ShellTail, text, saved, last) where {F}
    remember!(saved, snapshot.file)
    last[] = text
    update(callback, ShellUpdate(text, snapshot.file))
    nothing
end

function refresh!(callback::F, io, file, measure::ShellMeasure, saved, last) where {F}
    size = filesize(io)
    size == measure.bytes && return
    snapshot = tail(io, file, measure!(measure, io, size)...)
    snapshot = bound(snapshot, file, live(snapshot.text))
    shellupdate!(callback, snapshot, snapshot.text, saved, last)
end

function finishoutput!(callback::F, io, file, measure::ShellMeasure, saved, last) where {F}
    before = measure.bytes
    snapshot = tail(io, file, measure!(measure, io, filesize(io))...)
    snapshot = bound(snapshot, file, shelltext(snapshot.text))
    text = snapshot.text
    before == measure.bytes && text == last[] && return
    shellupdate!(callback, snapshot, text, saved, last)
end

function waitoutput(run::ShellRun, watcher, ::Nothing, file, saved)
    outcome = take!(run.done)
    waitfor(watcher, outcome)
    outcome
end

function waitoutput(run::ShellRun, watcher, callback::F, file, saved) where {F}
    open(file) do io
        measure = ShellMeasure()
        last = Ref("")
        while !isready(run.done)
            refresh!(callback, io, file, measure, saved, last)
            sleep(0.1)
        end
        outcome = take!(run.done)
        waitfor(watcher, outcome)
        finishoutput!(callback, io, file, measure, saved, last)
        outcome
    end
end

chunk!(chunks::ShellChunks, io) = chunk!(chunks, io, ShellMore())
function chunk!(chunks::ShellChunks, io, ending::ShellChunkEnd)
    seek(io, chunks.offset)
    data = read(io)
    chunks.offset += length(data)
    append!(chunks.pending, data)
    text = String(copy(chunks.pending))
    ready = chunktext(text, ending)
    consumed = chunkcount(text, ready, ending)
    deleteat!(chunks.pending, 1:consumed)
    cleaned = sanitize!(chunks, ready)
    if !isempty(cleaned)
        write(chunks.io, cleaned)
        chunks.callback(cleaned)
    end
    nothing
end
chunktext(text, ::ShellMore) = live(text)
chunktext(text, ::ShellFinal) = shelltext(text)
chunkcount(text, ready, ::ShellFinal) = ncodeunits(text)
chunkcount(text, ready, ::ShellMore) = ready == shelltext(text) ? ncodeunits(text) : lastindex(text) - 1

function sanitize!(chunks::ShellChunks, text)
    buffer = IOBuffer()
    escape = chunks.escape
    for char in text
        escape = sanitize!(buffer, escape, char)
    end
    chunks.escape = escape
    String(take!(buffer))
end

function sanitize!(io, ::ShellText, char)
    char == '\e' && return ShellEsc()
    (char == '\r' || '\x00' <= char <= '\x08' || '\x0b' <= char <= '\x0c' || '\x0e' <= char <= '\x1f' || '\ufff9' <= char <= '\ufffb') || print(io, char)
    ShellText()
end
const shellescapes = Dict('[' => ShellCSI(), ']' => ShellOSC())
sanitize!(io, ::ShellEsc, char) = get(shellescapes, char, ShellText())
sanitize!(io, ::ShellCSI, char) = '@' <= char <= '~' ? ShellText() : ShellCSI()
sanitize!(io, ::ShellOSC, char) = char == '\a' ? ShellText() : char == '\e' ? ShellOSCEsc() : ShellOSC()
sanitize!(io, ::ShellOSCEsc, char) = char == '\\' ? ShellText() : ShellOSC()

function waitoutput(run::ShellRun, watcher, chunks::ShellChunks, file, saved)
    open(file) do io
        while !isready(run.done)
            chunk!(chunks, io)
            sleep(0.1)
        end
        outcome = take!(run.done)
        waitfor(watcher, outcome)
        chunk!(chunks, io, ShellFinal())
        outcome
    end
end

finishreport!(callback, outcome, io, file, process) = nothing
function finishreport!(chunks::ShellChunks, outcome, io, file, process)
    flush(chunks.io)
    snapshot = tail(chunks.io, chunks.file, measure(chunks.io)...)
    snapshot = bound(snapshot, chunks.file, shelltext(snapshot.text))
    retained = retainedfile(snapshot.file, chunks)
    chunks.report = ShellReport(snapshot, retained, outcome, shellexit(outcome, process))
    nothing
end
retainedfile(file::String, chunks) = file
retainedfile(::Nothing, chunks) = chunks.offset > 51200 && filesize(chunks.io) > 0 ? chunks.file : nothing
shellexit(::ShellOutcome, process) = nothing
shellexit(::ShellComplete, process) = process.termsignal == 0 ? process.exitcode : 128 + process.termsignal

function execute(tool::Union{Bash, PowerShell}, args; cancel=nothing, on_update=nothing)
    update(on_update, ShellUpdate("", nothing))
    timeout = get(args, :timeout, nothing)
    execute(tool, args, cancel, timeout, on_update, timeoutcheck(timeout))
end

timeoutcheck(::Nothing) = nothing
function timeoutcheck(timeout)
    (!isfinite(timeout) || timeout <= 0) && return ToolFailure("Invalid timeout: must be a finite number of seconds")
    timeout * 1000 > 2147483647 && return ToolFailure("Invalid timeout: maximum is 2147483.647 seconds")
    nothing
end

execute(tool::Union{Bash, PowerShell}, args, cancel, timeout, on_update, failure::ToolFailure) = failure
execute(tool::Union{Bash, PowerShell}, args, cancel, timeout, on_update, ::Nothing) = shelloptions(tool, args, cancel, timeout, on_update)
function shelloptions(tool, args, cancel, timeout, on_update)
    !isdir(tool.cwd) && return ToolFailure("Working directory does not exist: $(tool.cwd)\nCannot execute $(shellname(tool)) commands.")
    shell(tool, args, cancel, timeout, config(tool), on_update)
end

shell(tool::Bash, args, cancel, timeout, ::Nothing, on_update) = ToolFailure("No $(shellname(tool)) executable found.")
shell(tool::PowerShell, args, cancel, timeout, ::Nothing, on_update) = ToolFailure(Sys.iswindows() ? "No $(shellname(tool)) executable found." : "The powershell tool is only available on Windows.")

startshell!(::Nothing, command, io) = nothing
function startshell!(runs::Set{ShellRun}, command, io)
    process = run(pipeline(ignorestatus(command); stdin=devnull, stdout=io, stderr=io); wait=false)
    shellrun = ShellRun(process)
    push!(runs, shellrun)
    shellrun
end

shellgate(tool::Union{Bash, PowerShell}, env, cancel, timeout, command) = nothing
cleanupgate(::Nothing) = nothing
cleanupgate(file::String) = rm(file; force=true)

@static if Sys.iswindows()
    include("system_windows.jl")
else
    shellcommand(tool::Union{Bash, PowerShell}, command, cancel, timeout, gate) = shellcommand(tool, command)
    startshell!(runs, command, io, cancel, timeout, gate) = startshell!(runs, command, io)
end

closejob(::Nothing) = nothing
waitjob(outcome::ShellOutcome, ::Nothing) = outcome

shellrun!(::Nothing, token, timeout, on_update, file, io, saved, keep) = ToolFailure("Command aborted")
function shellrun!(shellrun::ShellRun, token, timeout, on_update, file, io, saved, keep)
    watcher = nothing
    timer = nothing
    try
        process = shellrun.process
        watcher = @async begin
            wait(process)
            signal!(shellrun, ShellComplete())
        end
        timer = deadline(shellrun, timeout)
        outcome = waitjob(waitoutput(shellrun, watcher, on_update, file, saved), shellrun.job)
        flush(io)
        finishreport!(on_update, outcome, io, file, process)
        output, keep[] = tail(io, file)
        shellresult(outcome, output, timeout, process)
    finally
        cleanup!(timer)
        try
            cleanup!(token, shellrun, watcher)
        finally
            closejob(shellrun.job)
        end
    end
end

function shell(tool::Union{Bash, PowerShell}, args, cancel, timeout, settings::Tuple, on_update)
    env = copy(ENV)
    for key in ("PI_SESSION_ID", "PI_SESSION_FILE", "PI_PROVIDER", "PI_MODEL", "PI_REASONING_LEVEL")
        delete!(env, key)
    end
    gate = shellgate(tool, env, cancel, timeout, args.command)
    shell(tool, args, cancel, timeout, settings, on_update, env, gate)
end

shell(tool, args, cancel, timeout, settings, on_update, env, failure::ToolFailure) = failure
function shell(tool, args, cancel, timeout, settings, on_update, env, gate)
    executable, arguments = settings
    try
        command = Cmd(Cmd([executable; arguments; shellcommand(tool, args.command, cancel, timeout, gate)]); dir=tool.cwd, detach=!Sys.iswindows(), env)
        file, io = mktemp(; cleanup=false)
        keep = Ref{Union{Nothing, String}}(nothing)
        saved = Ref{Union{Nothing, String}}(nothing)
        token = cancellation(cancel)
        try
            shellrun = lock(token.lock) do
                startshell!(token.runs, command, io, cancel, timeout, gate)
            end
            shellrun!(shellrun, token, timeout, on_update, file, io, saved, keep)
        finally
            close(io)
            cleanupoutput(file, keep[], saved[])
        end
    finally
        cleanupgate(gate)
    end
end

struct LimitedOutput
    text::String
end

headtext(text::String) = text
headtext(output::LimitedOutput) = output.text
headnotice!(notices, ::String) = nothing
headnotice!(notices, ::LimitedOutput) = push!(notices, "50.0KB limit reached")

function head(lines)
    output = String[]
    bytes = 0
    for line in lines
        nextbytes = bytes + ncodeunits(line) + !isempty(output)
        nextbytes > 51200 && return LimitedOutput(join(output, '\n'))
        push!(output, line)
        bytes = nextbytes
    end
    join(output, '\n')
end

struct LimitedEntries
    entries::Vector{String}
end

entrylist(entries::Vector{String}) = entries
entrylist(entries::LimitedEntries) = entries.entries
entrynotice!(notices, ::Vector{String}, limit) = nothing
entrynotice!(notices, ::LimitedEntries, limit) = push!(notices, "$limit entries limit reached. Use limit=$(limit * 2) for more")

function listentries(entries, directory, limit)
    results = String[]
    for entry in entries
        length(results) >= limit && return LimitedEntries(results)
        target = joinpath(directory, entry)
        ispath(target) || continue
        push!(results, entry * (isdir(target) ? "/" : ""))
    end
    results
end

function execute(tool::Ls, args)
    directory = path(tool, get(args, :path, "."))
    !ispath(directory) && return ToolFailure("Path not found: $directory")
    !isdir(directory) && return ToolFailure("Not a directory: $directory")
    entries = sort!(readdir(directory); by=lowercase)
    limit = get(args, :limit, 500)
    result = listentries(entries, directory, limit)
    results = entrylist(result)
    isempty(results) && return ToolResult("(empty directory)")
    bounded = head(results)
    notices = String[]
    entrynotice!(notices, result, limit)
    headnotice!(notices, bounded)
    output = headtext(bounded)
    !isempty(notices) && (output *= "\n\n[$(join(notices, ". "))]")
    ToolResult(output)
end
