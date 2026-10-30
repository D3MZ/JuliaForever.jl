struct Bash <: Tool
    cwd::String
end

struct PowerShell <: Tool
    cwd::String
end

struct Ls <: Tool
    cwd::String
end

export ShellCancellation

abstract type ShellOutcome end
struct ShellComplete <: ShellOutcome end
struct ShellTimeout <: ShellOutcome end
struct ShellCancelled <: ShellOutcome end
struct ShellStopFailed <: ShellOutcome end
struct Signalled end

mutable struct ShellRun
    process::Base.Process
    lock::ReentrantLock
    outcome::Union{Nothing, ShellOutcome}
    done::Channel{ShellOutcome}
end

ShellRun(process::Base.Process) = ShellRun(process, ReentrantLock(), nothing, Channel{ShellOutcome}(1))

mutable struct ShellCancellation
    lock::ReentrantLock
    cancelled::Bool
    runs::Set{ShellRun}
end

ShellCancellation() = ShellCancellation(ReentrantLock(), false, Set{ShellRun}())

cancel!(::Nothing) = nothing

function cancel!(cancel::ShellCancellation)
    lock(cancel.lock) do
        cancel.cancelled = true
        foreach(run -> signal!(run, ShellCancelled()), cancel.runs)
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

function config(::Bash)
    if Sys.iswindows()
        for base in (get(ENV, "ProgramFiles", ""), get(ENV, "ProgramFiles(x86)", ""))
            candidate = joinpath(base, "Git", "bin", "bash.exe")
            !isempty(base) && isfile(candidate) && return (candidate, ["-c"])
        end
        executable = Sys.which("bash.exe")
        return isnothing(executable) ? nothing : (executable, ["-c"])
    end
    executable = isfile("/bin/bash") ? "/bin/bash" : something(Sys.which("bash"), "sh")
    (executable, ["-c"])
end

function config(::PowerShell)
    Sys.iswindows() || return nothing
    executable = Sys.which("pwsh.exe")
    if isnothing(executable)
        candidate = joinpath(get(ENV, "ProgramFiles", ""), "PowerShell", "7", "pwsh.exe")
        isfile(candidate) && (executable = candidate)
    end
    isnothing(executable) && (executable = Sys.which("powershell.exe"))
    if isnothing(executable)
        candidate = joinpath(get(ENV, "SystemRoot", ""), "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
        isfile(candidate) && (executable = candidate)
    end
    isnothing(executable) ? nothing : (executable, ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command"])
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

stop(process::Base.Process, ::ShellComplete) = ShellComplete()

function stop(process::Base.Process, requested::Union{ShellTimeout, ShellCancelled})
    result = Sys.iswindows() ? ShellStopFailed() : stop(process)
    stop(requested, result)
end

stop(requested::ShellOutcome, ::Signalled) = requested
stop(requested::ShellOutcome, result::Union{ShellComplete, ShellStopFailed}) = result

function signal!(run::ShellRun, outcome::ShellOutcome)
    lock(run.lock) do
        signal!(run, outcome, run.outcome)
    end
end

signal!(run::ShellRun, outcome::ShellOutcome, previous::ShellOutcome) = nothing

function signal!(run::ShellRun, outcome::ShellOutcome, ::Nothing)
    result = stop(run.process, outcome)
    run.outcome = result
    put!(run.done, result)
    nothing
end

cancellation(::Nothing) = ShellCancellation()
cancellation(cancel::ShellCancellation) = cancel
deadline(run::ShellRun, ::Nothing) = nothing
deadline(run::ShellRun, timeout::Real) = Timer(_ -> signal!(run, ShellTimeout()), timeout)
waitfor(::Nothing, outcome::ShellOutcome) = nothing
waitfor(task::Task, ::ShellStopFailed) = nothing
waitfor(task::Task, outcome::ShellOutcome) = wait(task)
cleanup!(::Nothing) = nothing
cleanup!(timer::Timer) = close(timer)
cleanup!(token::ShellCancellation, ::Nothing, watcher) = nothing

function cleanup!(token::ShellCancellation, run::ShellRun, watcher)
    lock(token.lock) do
        delete!(token.runs, run)
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

function measure(io)
    seekstart(io)
    bytes = 0
    newlines = 0
    lastline = 0
    completed = 0
    lastbyte = UInt8(0)
    while !eof(io)
        block = read(io, 65536)
        bytes += length(block)
        for byte in block
            lastbyte = byte
            if byte == 0x0a
                newlines += 1
                completed = lastline
                lastline = 0
            else
                lastline += 1
            end
        end
    end
    lines = newlines + (bytes > 0 && lastbyte != 0x0a)
    (bytes, lines, lastbyte == 0x0a ? completed : lastline)
end

function sizeformat(bytes)
    bytes < 1024 && return "$(bytes)B"
    bytes < 1024 * 1024 && return "$(round(bytes / 1024; digits=1))KB"
    "$(round(bytes / (1024 * 1024); digits=1))MB"
end

function tail(io, file)
    bytes, lines, lastsize = measure(io)
    if bytes <= 51200 && lines <= 2000
        seekstart(io)
        return (String(read(io)), false)
    end
    offset = max(0, bytes - 51201)
    preceding = offset > 0 ? (seek(io, offset - 1); read(io, UInt8)) : 0x0a
    seek(io, offset)
    data = read(io)
    !isempty(data) && last(data) == 0x0a && pop!(data)
    pieces = split(String(data), '\n'; keepempty=true)
    selected = SubString{String}[]
    used = 0
    partial = false
    bybytes = false
    for piece in Iterators.reverse(pieces)
        length(selected) == 2000 && break
        needed = ncodeunits(piece) + !isempty(selected)
        if used + needed > 51200
            bybytes = true
            if isempty(selected)
                raw = collect(codeunits(piece))
                start = max(1, length(raw) - 51200 + 1)
                while start <= length(raw) && raw[start] & 0xc0 == 0x80
                    start += 1
                end
                pushfirst!(selected, SubString(String(raw[start:end])))
                partial = true
            end
            break
        end
        pushfirst!(selected, piece)
        used += needed
    end
    # The first fragment from a bounded read may start in the middle of an earlier line.
    if offset > 0 && preceding != 0x0a && length(selected) == length(pieces) && !partial
        popfirst!(selected)
        bybytes = true
    end
    output = join(selected, '\n')
    if partial
        notice = "Showing last $(sizeformat(ncodeunits(output))) of line $lines (line is $(sizeformat(lastsize))). Full output: $file"
    else
        firstline = lines - length(selected) + 1
        limit = bybytes && length(selected) < 2000 ? " (50.0KB limit)" : ""
        notice = "Showing lines $firstline-$lines of $lines$limit. Full output: $file"
    end
    ("$output\n\n[$notice]", true)
end

function execute(tool::Union{Bash, PowerShell}, args; cancel=nothing)
    timeout = get(args, :timeout, nothing)
    !isnothing(timeout) && (!isfinite(timeout) || timeout <= 0) && return ToolFailure("Invalid timeout: must be a finite number of seconds")
    !isnothing(timeout) && timeout * 1000 > 2147483647 && return ToolFailure("Invalid timeout: maximum is 2147483.647 seconds")
    Sys.iswindows() && !isnothing(timeout) && return ToolFailure("Timeout is not supported on Windows")
    Sys.iswindows() && !isnothing(cancel) && return ToolFailure("Cancellation is not supported on Windows")
    !isdir(tool.cwd) && return ToolFailure("Working directory does not exist: $(tool.cwd)\nCannot execute $(shellname(tool)) commands.")
    settings = config(tool)
    if isnothing(settings)
        message = tool isa PowerShell && !Sys.iswindows() ? "The powershell tool is only available on Windows." : "No $(shellname(tool)) executable found."
        return ToolFailure(message)
    end
    executable, arguments = settings
    env = copy(ENV)
    for key in ("PI_SESSION_ID", "PI_SESSION_FILE", "PI_PROVIDER", "PI_MODEL", "PI_REASONING_LEVEL")
        delete!(env, key)
    end
    command = Cmd(Cmd([executable; arguments; shellcommand(tool, args.command)]); dir=tool.cwd, detach=!Sys.iswindows(), env)
    file, io = mktemp(; cleanup=false)
    keep = false
    token = cancellation(cancel)
    shellrun = nothing
    watcher = nothing
    timer = nothing
    try
        shellrun = lock(token.lock) do
            token.cancelled && return nothing
            process = run(pipeline(ignorestatus(command); stdin=devnull, stdout=io, stderr=io); wait=false)
            shellrun = ShellRun(process)
            push!(token.runs, shellrun)
            shellrun
        end
        isnothing(shellrun) && return ToolFailure("Command aborted")
        process = shellrun.process
        watcher = @async begin
            wait(process)
            signal!(shellrun, ShellComplete())
        end
        timer = deadline(shellrun, timeout)
        outcome = take!(shellrun.done)
        waitfor(watcher, outcome)
        flush(io)
        output, keep = tail(io, file)
        shellresult(outcome, output, timeout, process)
    finally
        cleanup!(timer)
        cleanup!(token, shellrun, watcher)
        close(io)
        !keep && rm(file; force=true)
    end
end

function head(lines)
    output = String[]
    bytes = 0
    for line in lines
        nextbytes = bytes + ncodeunits(line) + !isempty(output)
        nextbytes > 51200 && return (join(output, '\n'), true)
        push!(output, line)
        bytes = nextbytes
    end
    (join(output, '\n'), false)
end

function execute(tool::Ls, args)
    directory = path(tool, get(args, :path, "."))
    !ispath(directory) && return ToolFailure("Path not found: $directory")
    !isdir(directory) && return ToolFailure("Not a directory: $directory")
    entries = sort!(readdir(directory); by=lowercase)
    limit = get(args, :limit, 500)
    results = String[]
    reached = false
    for entry in entries
        if length(results) >= limit
            reached = true
            break
        end
        target = joinpath(directory, entry)
        ispath(target) || continue
        push!(results, entry * (isdir(target) ? "/" : ""))
    end
    isempty(results) && return ToolResult("(empty directory)")
    output, truncated = head(results)
    notices = String[]
    reached && push!(notices, "$limit entries limit reached. Use limit=$(limit * 2) for more")
    truncated && push!(notices, "50.0KB limit reached")
    !isempty(notices) && (output *= "\n\n[$(join(notices, ". "))]")
    ToolResult(output)
end
