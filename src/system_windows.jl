struct WindowsBasicLimits
    process_time::Int64
    job_time::Int64
    flags::UInt32
    minimum_working_set::Csize_t
    maximum_working_set::Csize_t
    active_processes::UInt32
    affinity::Csize_t
    priority::UInt32
    scheduling::UInt32
end

struct WindowsIOCounters
    read_operations::UInt64
    write_operations::UInt64
    other_operations::UInt64
    read_bytes::UInt64
    write_bytes::UInt64
    other_bytes::UInt64
end

struct WindowsJobLimits
    basic::WindowsBasicLimits
    io::WindowsIOCounters
    process_memory::Csize_t
    job_memory::Csize_t
    peak_process_memory::Csize_t
    peak_job_memory::Csize_t
end

struct WindowsJobAccounting
    total_user::Int64
    total_kernel::Int64
    period_user::Int64
    period_kernel::Int64
    faults::UInt32
    total::UInt32
    active::UInt32
    terminated::UInt32
end

struct BashGate
    file::String
    pidfile::String
end

struct PowerShellGate
    pidfile::String
    name::String
end

struct FileRemoved end
struct FileRemovalFailed end
const filedeletions = Dict(:ok => FileRemoved(), :timed_out => FileRemovalFailed())

function deleteoutput(file::String)
    path = transcode(UInt16, file * '\0')
    ccall((:DeleteFileW, "kernel32"), Int32, (Ptr{UInt16},), path) != 0 && return true
    ccall((:GetLastError, "kernel32"), UInt32, ()) in (2, 3)
end

function removeoutput(file::String, ::Nothing)
    outcome = get(filedeletions, timedwait(() -> deleteoutput(file), 2; pollint=0.01), FileRemovalFailed())
    finishdelete(file, outcome)
end
finishdelete(file, ::FileRemoved) = nothing
finishdelete(file, ::FileRemovalFailed) = rm(file; force=true)

function windowsjob()
    handle = ccall((:CreateJobObjectW, "kernel32"), Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{UInt16}), C_NULL, C_NULL)
    handle == C_NULL && return ToolFailure("Could not isolate Windows shell; command was not started")
    basic = WindowsBasicLimits(0, 0, 0x00002000, 0, 0, 0, 0, 0, 0)
    counters = WindowsIOCounters(0, 0, 0, 0, 0, 0)
    limits = Ref(WindowsJobLimits(basic, counters, 0, 0, 0, 0))
    configured = ccall((:SetInformationJobObject, "kernel32"), Int32, (Ptr{Cvoid}, Int32, Ref{WindowsJobLimits}, UInt32), handle, 9, limits, sizeof(WindowsJobLimits))
    if configured == 0
        ccall((:CloseHandle, "kernel32"), Int32, (Ptr{Cvoid},), handle)
        return ToolFailure("Could not isolate Windows shell; command was not started")
    end
    WindowsJob(handle)
end

function closejob(job::WindowsJob)
    ccall((:CloseHandle, "kernel32"), Int32, (Ptr{Cvoid},), job.handle)
    nothing
end

function assign(job::WindowsJob, process::Base.Process)
    Base.iolock_begin()
    try
        process_exited(process) && return false
        pid = ccall(:jl_uv_process_pid, Cint, (Ptr{Cvoid},), process.handle)
        handle = ccall((:OpenProcess, "kernel32"), Ptr{Cvoid}, (UInt32, Int32, UInt32), 0x00000101, 0, pid)
        assign(job, handle)
    finally
        Base.iolock_end()
    end
end

function assign(job::WindowsJob, handle::Ptr{Cvoid})
    handle == C_NULL && return false
    try
        ccall((:AssignProcessToJobObject, "kernel32"), Int32, (Ptr{Cvoid}, Ptr{Cvoid}), job.handle, handle) != 0
    finally
        ccall((:CloseHandle, "kernel32"), Int32, (Ptr{Cvoid},), handle)
    end
end

function stop(process::Base.Process, job::WindowsJob)
    Base.iolock_begin()
    try
        process_exited(process) && return ShellComplete()
    finally
        Base.iolock_end()
    end
    ccall((:TerminateJobObject, "kernel32"), Int32, (Ptr{Cvoid}, UInt32), job.handle, 1) == 0 ? ShellStopFailed() : Signalled()
end

function jobempty(job::WindowsJob)
    accounting = Ref(WindowsJobAccounting(0, 0, 0, 0, 0, 0, 0, 0))
    queried = ccall((:QueryInformationJobObject, "kernel32"), Int32, (Ptr{Cvoid}, Int32, Ref{WindowsJobAccounting}, UInt32, Ptr{UInt32}), job.handle, 1, accounting, sizeof(WindowsJobAccounting), C_NULL)
    queried != 0 && accounting[].active == 0
end

function jobcontains(job::WindowsJob, pid::UInt)
    pid == 0 && return false
    data = zeros(UInt8, 8 + 64 * sizeof(UInt))
    queried = ccall((:QueryInformationJobObject, "kernel32"), Int32, (Ptr{Cvoid}, Int32, Ptr{UInt8}, UInt32, Ptr{UInt32}), job.handle, 3, data, length(data), C_NULL)
    count = reinterpret(UInt32, data)[2]
    ids = reinterpret(UInt, @view data[9:end])
    queried != 0 && count <= length(ids) && pid in @view(ids[1:count])
end

waitjob(outcome::ShellStopFailed, job::WindowsJob) = outcome
const windowsjoboutcomes = Dict(:ok => ShellComplete(), :timed_out => ShellStopFailed())
joboutcome(outcome, ::ShellComplete) = outcome
joboutcome(outcome, failure::ShellStopFailed) = failure
waitjob(outcome::Union{ShellTimeout, ShellCancelled}, job::WindowsJob) = joboutcome(outcome, get(windowsjoboutcomes, timedwait(() -> jobempty(job), 5; pollint=0.01), ShellStopFailed()))
function waitjob(outcome::ShellComplete, job::WindowsJob)
    jobempty(job) && return outcome
    ccall((:TerminateJobObject, "kernel32"), Int32, (Ptr{Cvoid}, UInt32), job.handle, 1) == 0 && return ShellStopFailed()
    joboutcome(outcome, get(windowsjoboutcomes, timedwait(() -> jobempty(job), 5; pollint=0.01), ShellStopFailed()))
end

shellcommand(tool::Union{Bash, PowerShell}, command, cancel, timeout, ::Nothing) = shellcommand(tool, command)
shellcommand(::Bash, command, cancel, timeout, ::BashGate) = ":"
function shellcommand(tool::PowerShell, command, cancel, timeout, gate::PowerShellGate)
    "[IO.File]::WriteAllText([Environment]::GetEnvironmentVariable('" * gate.name * "'), [string]\$PID + \"`n\")\n" *
    "[Environment]::SetEnvironmentVariable('" * gate.name * "', \$null)\n" *
    "if ([Console]::In.ReadLine() -ne 'ready') { exit 1 }\n" * shellcommand(tool, command)
end

shellgate(::PowerShell, env, ::Nothing, ::Nothing, command) = nothing
function shellgate(::PowerShell, env, cancel, timeout, command)
    profilers = ("CORECLR_ENABLE_PROFILING", "DOTNET_ENABLE_PROFILING", "COR_ENABLE_PROFILING")
    for (name, value) in env
        key = uppercase(name)
        (key == "DOTNET_STARTUP_HOOKS" && !isempty(value) || key in profilers && !(isempty(value) || value == "0")) && return ToolFailure("Could not isolate PowerShell with a .NET startup hook or profiler; command was not started")
    end
    pidfile, io = mktemp()
    close(io)
    name = "JF_POWERSHELL_GATE_" * replace(basename(pidfile), r"[^A-Za-z0-9]" => "_")
    env[name] = pidfile
    PowerShellGate(pidfile, name)
end

bashstartup!(env, ::Nothing, file) = "unset BASH_ENV\n"
function bashstartup!(env, value::AbstractString, file)
    name = "JF_BASH_ENV_" * replace(basename(file), r"[^A-Za-z0-9]" => "_")
    env[name] = value
    "export BASH_ENV=\"\${" * name * "}\"\nunset " * name * "\n"
end

function bashenvironment!(env)
    for name in keys(env)
        uppercase(name) == "BASH_ENV" && return pop!(env, name)
    end
    nothing
end

shellgate(::Bash, env, ::Nothing, ::Nothing, command) = nothing
function shellgate(::Bash, env, cancel, timeout, command)
    file, io = mktemp()
    pidfile, pidio = mktemp()
    close(pidio)
    try
        startup = bashstartup!(env, bashenvironment!(env), file)
        name = "JF_BASH_GATE_" * replace(basename(file), r"[^A-Za-z0-9]" => "_")
        pidname = name * "_PID"
        pidvalue = pidname * "_VALUE"
        commandname = name * "_COMMAND"
        commandvalue = commandname * "_VALUE"
        env[name] = replace(file, '\\' => '/')
        env[pidname] = replace(pidfile, '\\' => '/')
        env[commandname] = command
        env["BASH_ENV"] = "\${" * name * "}"
        write(io, "IFS= read -r " * pidvalue * " < /proc/\$\$/winpid || :\n", "printf '%s\\n' \"\${" * pidvalue * "}\" > \"\${" * pidname * "}\"\n", "unset " * pidvalue * " " * pidname * "\n", "(IFS= read -r ready) || exit 1\n", startup, commandvalue * "=\"\${" * commandname * "}\"\n", "unset " * name * " " * commandname * "\n", raw"""
        SHLVL=$((SHLVL - 1))
        """, "\"\$BASH\" -c \"\${" * commandvalue * "}\" \"\$0\"\nexit \"\$?\"\n")
    finally
        close(io)
    end
    BashGate(file, pidfile)
end

cleanupgate(gate::PowerShellGate) = removeoutput(gate.pidfile, nothing)
function cleanupgate(gate::BashGate)
    removeoutput(gate.file, nothing)
    removeoutput(gate.pidfile, nothing)
    nothing
end

function gatepid(gate::Union{BashGate, PowerShellGate})
    text = read(gate.pidfile, String)
    endswith(text, "\n") || return UInt(0)
    something(tryparse(UInt, strip(text)), UInt(0))
end

gatewait(job, ::Nothing) = 10.0
gatewait(job, timeout::Real) = min(duration(job, timeout), 10.0)
checkgate(job, process, ::Nothing, timeout) = nothing
const gateoutcomes = Dict(:ok => ShellComplete(), :timed_out => ShellTimeout())
function checkgate(job, process, gate::Union{BashGate, PowerShellGate}, timeout)
    outcome = get(gateoutcomes, timedwait(() -> gatepid(gate) > 0 || process_exited(process), gatewait(job, timeout); pollint=0.01), ShellTimeout())
    gateoutcome(job, gate, timeout, outcome)
end
function gateoutcome(job, gate, timeout, ::ShellComplete)
    jobcontains(job, gatepid(gate)) ? gatedeadline(job, timeout) : ToolFailure("Could not isolate Windows shell; command was not started")
end
gatedeadline(job, ::Nothing) = nothing
gatedeadline(job, timeout::Real) = duration(job, timeout) > 0 ? nothing : ToolFailure("Command timed out after $timeout seconds")
gateoutcome(job, gate, ::Nothing, ::ShellTimeout) = ToolFailure("Could not isolate Windows shell; command was not started")
gateoutcome(job, gate, timeout::Real, ::ShellTimeout) = duration(job, timeout) <= 0 ? ToolFailure("Command timed out after $timeout seconds") : ToolFailure("Could not isolate Windows shell; command was not started")

startshell!(::Nothing, command, io, cancel, timeout, gate) = nothing
startshell!(runs::Set{ShellRun}, command, io, ::Nothing, ::Nothing, gate) = startshell!(runs, command, io)
startshell!(runs::Set{ShellRun}, command, io, cancel, timeout, gate) = startjob!(runs, command, io, windowsjob(), gate, timeout)
startjob!(runs, command, io, failure::ToolFailure, gate, timeout) = failure
startshell!(runs::Set{ShellRun}, command, io, job::WindowsJob) = startjob!(runs, command, io, job, nothing, nothing)

function startjob!(runs::Set{ShellRun}, command, io, job::WindowsJob, shellgate, timeout)
    gate = Pipe()
    process = Ref{Union{Nothing, Base.Process}}(nothing)
    registered = Ref{Union{Nothing, ShellRun}}(nothing)
    try
        process[] = run(pipeline(ignorestatus(command); stdin=gate, stdout=io, stderr=io); wait=false)
        close(gate.out)
        assign(job, process[]) || return ToolFailure("Could not isolate Windows shell; command was not started")
        result = gated!(runs, process[], job, gate, checkgate(job, process[], shellgate, timeout))
        registershell!(registered, result)
    finally
        close(gate)
        cleanupstart(registered[], process[], job)
    end
end

gated!(runs, process, job, gate, failure::ToolFailure) = failure
function gated!(runs, process, job, gate, ::Nothing)
    write(gate, "ready\n")
    shellrun = ShellRun(process, job)
    push!(runs, shellrun)
    shellrun
end
registershell!(registered, failure::ToolFailure) = failure
function registershell!(registered, run::ShellRun)
    registered[] = run
    run
end

cleanupstart(run::ShellRun, process, job) = nothing
function cleanupstart(::Nothing, process, job)
    closejob(job)
    cleanupstart(process)
end
cleanupstart(::Nothing) = nothing
function cleanupstart(process::Base.Process)
    timedwait(() -> process_exited(process), 5; pollint=0.01)
    process_running(process) && kill(process)
    wait(process)
    nothing
end

shellrun!(failure::ToolFailure, token, timeout, on_update, file, io, saved, keep) = failure
