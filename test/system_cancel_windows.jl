module SystemCancelWindows

using Test, JuliaForever, JSON3

psquote(value) = "'" * replace(string(value), "'" => "''") * "'"
bashquote(value) = "'" * replace(string(value), "'" => "'\\''") * "'"

function fixture(dir, label)
    leader, child, grandchild, ready, release, late = [joinpath(dir, "$label-$name") for name in ("leader", "child", "grandchild", "ready", "release", "late")]
    childscript, grandscript = joinpath(dir, "$label-child.ps1"), joinpath(dir, "$label-grandchild.ps1")
    grand = raw"""
    $ErrorActionPreference = 'Stop'
    [IO.File]::WriteAllText(__GRAND__, [string]$PID)
    [IO.File]::WriteAllText(__READY__, 'ready')
    while (!(Test-Path -LiteralPath __RELEASE__)) { Start-Sleep -Milliseconds 50 }
    [IO.File]::WriteAllText(__LATE__, 'late')
    """
    childcode = raw"""
    $ErrorActionPreference = 'Stop'
    [IO.File]::WriteAllText(__CHILD__, [string]$PID)
    $exe = (Get-Process -Id $PID).Path
    $p = Start-Process -FilePath $exe -ArgumentList ('-NoProfile -NonInteractive -File "' + __SCRIPT__ + '"') -PassThru
    $p.WaitForExit()
    """
    command = raw"""
    $ErrorActionPreference = 'Stop'
    [IO.File]::WriteAllText(__LEADER__, [string]$PID)
    [Console]::Out.Write('before')
    [Console]::Out.Flush()
    $exe = (Get-Process -Id $PID).Path
    $p = Start-Process -FilePath $exe -ArgumentList ('-NoProfile -NonInteractive -File "' + __SCRIPT__ + '"') -PassThru
    $p.WaitForExit()
    """
    write(grandscript, replace(grand, "__GRAND__" => psquote(grandchild), "__READY__" => psquote(ready), "__RELEASE__" => psquote(release), "__LATE__" => psquote(late)))
    write(childscript, replace(childcode, "__CHILD__" => psquote(child), "__SCRIPT__" => psquote(grandscript)))
    command = replace(command, "__LEADER__" => psquote(leader), "__SCRIPT__" => psquote(childscript))
    (; command, leader, child, grandchild, ready, release, late)
end

function alive(pid)
    handle = ccall((:OpenProcess, "kernel32"), Ptr{Cvoid}, (UInt32, Int32, UInt32), 0x00100000, 0, pid)
    handle == C_NULL && return ccall((:GetLastError, "kernel32"), UInt32, ()) != 87
    try
        ccall((:WaitForSingleObject, "kernel32"), UInt32, (Ptr{Cvoid}, UInt32), handle, 0) == 0x00000102
    finally
        ccall((:CloseHandle, "kernel32"), Int32, (Ptr{Cvoid},), handle)
    end
end

function members(job)
    data = zeros(UInt8, 8 + 64 * sizeof(UInt))
    result = ccall((:QueryInformationJobObject, "kernel32"), Int32, (Ptr{Cvoid}, Int32, Ptr{UInt8}, UInt32, Ptr{UInt32}), job.handle, 3, data, length(data), C_NULL)
    result == 0 && return UInt[]
    count = reinterpret(UInt32, data)[2]
    collect(reinterpret(UInt, @view data[9:end])[1:count])
end

function unrelated(shell)
    executable, arguments = JuliaForever.config(shell)
    cmd = Cmd([executable; arguments; "Start-Sleep -Seconds 60"])
    run(pipeline(ignorestatus(cmd); stdin=devnull, stdout=devnull, stderr=devnull); wait=false)
end

mutable struct WindowsProvider
    replies::Vector{Any}
end
JuliaForever.complete(provider::WindowsProvider, messages, tools) = popfirst!(provider.replies)

function reply(fixtures)
    calls = [Dict("id" => "shell-$i", "type" => "function", "function" => Dict("name" => "powershell", "arguments" => JSON3.write((; command=current.command)))) for (i, current) in enumerate(fixtures)]
    Dict("role" => "assistant", "content" => nothing, "tool_calls" => calls)
end

@testset "Windows shell cancellation" begin
    if Sys.iswindows()
        mktempdir() do dir
            shell = PowerShell(dir)
            @test !isnothing(JuliaForever.config(shell))
            token = ShellCancellation()
            cancel!(token)
            @test execute(shell, (; command="[IO.File]::WriteAllText('unexpected','bad')"); cancel=token) == ToolFailure("Command aborted")
            @test !isfile(joinpath(dir, "unexpected"))
            @test execute(shell, (; command="[Console]::Write('complete')")) == ToolSuccess("complete")
            @test execute(shell, (; command="[Console]::Write('complete')", timeout=30); cancel=ShellCancellation()) == ToolSuccess("complete")
            @test execute(shell, (; command="[Console]::Write('failure'); exit 7", timeout=30)) == ToolFailure("failure\n\nCommand exited with code 7")
            @test execute(shell, (; command="[IO.File]::WriteAllText('too-late','bad')", timeout=0.001)) == ToolFailure("Command timed out after 0.001 seconds")
            @test !isfile(joinpath(dir, "too-late"))
            executable, arguments = JuliaForever.config(shell)
            if lowercase(basename(executable)) == "pwsh.exe"
                hook = joinpath(dir, "startup-hook.dll")
                marker = joinpath(dir, "powershell-hook-ran")
                source = raw"""public static class StartupHook { public static void Initialize() { System.IO.File.WriteAllText(System.Environment.GetEnvironmentVariable("JF_HOOK_MARKER"), "started"); } }"""
                command = "Add-Type -TypeDefinition " * psquote(source) * " -OutputAssembly " * psquote(hook)
                run(Cmd([executable; arguments; command]))
                withenv("DOTNET_STARTUP_HOOKS" => hook, "JF_HOOK_MARKER" => marker) do
                    @test execute(shell, (; command="[Console]::Write('complete')")) == ToolSuccess("complete")
                    @test isfile(marker)
                    rm(marker; force=true)
                    @test execute(shell, (; command="[Console]::Write('complete')", timeout=30)) == ToolFailure("Could not isolate PowerShell with a .NET startup hook or profiler; command was not started")
                    @test !isfile(marker)
                end
            end
            for key in ("CORECLR_ENABLE_PROFILING", "DOTNET_ENABLE_PROFILING", "COR_ENABLE_PROFILING")
                withenv(key => "1") do
                    @test execute(shell, (; command="[Console]::Write('complete')", timeout=30)) == ToolFailure("Could not isolate PowerShell with a .NET startup hook or profiler; command was not started")
                end
            end
            withenv("CORECLR_ENABLE_PROFILING" => "0") do
                @test execute(shell, (; command="[Console]::Write('complete')", timeout=30)) == ToolSuccess("complete")
            end
            lockedfile, io = mktemp()
            close(io)
            lockedready = joinpath(dir, "locked-ready")
            lockedrelease = joinpath(dir, "locked-release")
            lockcommand = "\$f = [IO.File]::Open($(psquote(lockedfile)), 'Open', 'Read', 'None'); [IO.File]::WriteAllText($(psquote(lockedready)), 'ready'); while (!(Test-Path -LiteralPath $(psquote(lockedrelease)))) { Start-Sleep -Milliseconds 20 }; \$f.Dispose()"
            locker = run(pipeline(ignorestatus(Cmd([executable; arguments; lockcommand])); stdin=devnull, stdout=devnull, stderr=devnull); wait=false)
            try
                @test timedwait(() -> isfile(lockedready) || process_exited(locker), 15; pollint=0.05) == :ok
                @test isfile(lockedready)
                started = Channel{Nothing}(1)
                removing = Threads.@spawn begin
                    put!(started, nothing)
                    JuliaForever.removeoutput(lockedfile, nothing)
                end
                @test timedwait(() -> isready(started), 5; pollint=0.01) == :ok
                @test timedwait(() -> istaskdone(removing), 0.2; pollint=0.01) == :timed_out
                write(lockedrelease, "release")
                finished = timedwait(() -> istaskdone(removing), 5; pollint=0.01)
                @test finished == :ok
                finished == :ok && @test fetch(removing) === nothing
                @test !isfile(lockedfile)
            finally
                write(lockedrelease, "release")
                process_running(locker) && kill(locker)
                wait(locker)
                rm(lockedfile; force=true)
            end
            for command in ("[Console]::Write('a ''quoted'' value 🌱')", "cmd.exe /c exit 7")
                @test execute(shell, (; command, timeout=30)) == execute(shell, (; command))
            end
            modulepath = joinpath(dir, "JFGateFixture")
            mkdir(modulepath)
            modulemarker = joinpath(dir, "module-ran")
            write(joinpath(modulepath, "JFGateFixture.psm1"), "[IO.File]::WriteAllText(" * psquote(modulemarker) * ", 'loaded')\n")
            withenv("PSModulePath" => dir * ";" * get(ENV, "PSModulePath", "")) do
                command = "#Requires -Modules JFGateFixture\n[Console]::Write('complete')"
                env = copy(ENV)
                gatefile = JuliaForever.shellgate(shell, env, ShellCancellation(), 30, command)
                blocked = Cmd(Cmd([executable; arguments; JuliaForever.shellcommand(shell, command, ShellCancellation(), 30, gatefile)]); dir=dir, env)
                pipe = Pipe()
                process = run(pipeline(ignorestatus(blocked); stdin=pipe, stdout=devnull, stderr=devnull); wait=false)
                close(pipe.out)
                try
                    @test timedwait(() -> JuliaForever.gatepid(gatefile) > 0 || process_exited(process), 15; pollint=0.05) == :ok
                    @test JuliaForever.gatepid(gatefile) > 0
                    @test !isfile(modulemarker)
                finally
                    close(pipe)
                    timedwait(() -> process_exited(process), 10; pollint=0.05)
                    process_running(process) && kill(process)
                    wait(process)
                    JuliaForever.cleanupgate(gatefile)
                end
                @test !isfile(modulemarker)
                @test execute(shell, (; command, timeout=30)) == execute(shell, (; command))
                @test !isfile(modulemarker)
            end
            marker = joinpath(dir, "unassigned")
            blocked = "if ([Console]::In.ReadLine() -ne 'ready') { exit 1 }\n[IO.File]::WriteAllText($(psquote(marker)), 'unexpected')"
            cmd = Cmd(Cmd([executable; arguments; blocked]); dir=dir)
            other = unrelated(shell)
            try
                mktemp() do _, io
                    result = JuliaForever.startshell!(Set{JuliaForever.ShellRun}(), cmd, io, JuliaForever.WindowsJob(C_NULL))
                    @test result == ToolFailure("Could not isolate Windows shell; command was not started")
                end
                @test !isfile(marker)
                @test process_running(other)
            finally
                process_running(other) && kill(other)
                wait(other)
            end

            for mode in (:cancel, :timeout)
                current = fixture(dir, string(mode))
                token = ShellCancellation()
                other = unrelated(shell)
                updates = ShellUpdate[]
                timeout = mode == :timeout ? 10 : 60
                run = Threads.@spawn execute(shell, (; command=current.command, timeout); cancel=token, on_update=update -> push!(updates, update))
                try
                    @test timedwait(() -> isfile(current.ready) || istaskdone(run), 20; pollint=0.05) == :ok
                    @test isfile(current.ready)
                    if isfile(current.ready)
                        pids = parse.(UInt32, read.((current.leader, current.child, current.grandchild), String))
                        @test all(alive, pids)
                        job = lock(token.lock) do
                            only(token.runs).job
                        end
                        @test all(pid -> pid in members(job), pids)
                        mode == :cancel && cancel!(token)
                        finished = timedwait(() -> istaskdone(run), 15; pollint=0.05)
                        @test finished == :ok
                        if finished == :ok
                            expected = mode == :cancel ? "before\n\nCommand aborted" : "before\n\nCommand timed out after 10 seconds"
                            @test fetch(run) == ToolFailure(expected)
                            @test timedwait(() -> all(pid -> !alive(pid), pids), 5; pollint=0.05) == :ok
                            @test process_running(other)
                            @test any(update -> occursin("before", update.text), updates)
                            write(current.release, "release")
                            sleep(0.5)
                            @test !isfile(current.late)
                        end
                    end
                finally
                    cancel!(token)
                    write(current.release, "release")
                    process_running(other) && kill(other)
                    wait(other)
                end
            end

            background = fixture(dir, "background")
            awaitchild = "while (!(Test-Path -LiteralPath $(psquote(background.ready)))) { Start-Sleep -Milliseconds 50 }"
            command = replace(background.command, "\$p.WaitForExit()" => awaitchild)
            try
                @test execute(shell, (; command, timeout=30)) == ToolSuccess("before")
                @test isfile(background.ready)
                if isfile(background.ready)
                    pids = parse.(UInt32, read.((background.child, background.grandchild), String))
                    @test all(alive, pids)
                    write(background.release, "release")
                    @test timedwait(() -> isfile(background.late), 10; pollint=0.05) == :ok
                    @test timedwait(() -> all(pid -> !alive(pid), pids), 10; pollint=0.05) == :ok
                end
            finally
                write(background.release, "release")
            end

            large = execute(shell, (; command="[Console]::Write(('x' * 52001)); [Console]::Out.Flush(); Start-Sleep -Seconds 30", timeout=10))
            @test large.iserror && startswith(large.text, repeat("x", 51200))
            @test occursin("Command timed out after 10 seconds", large.text)
            output = match(r"Full output: (.+?)\]", large.text)
            @test !isnothing(output)
            if !isnothing(output)
                @test read(output.captures[1], String) == repeat("x", 52001)
                rm(output.captures[1]; force=true)
            end

            bash = Bash(dir)
            if !isnothing(JuliaForever.config(bash))
                @test execute(bash, (; command="printf bad > bash-too-late", timeout=0.001)) == ToolFailure("Command timed out after 0.001 seconds")
                @test !isfile(joinpath(dir, "bash-too-late"))
                withenv("BASH_ENV" => nothing, "SHLVL" => "5") do
                    command = "printf '%s|%s|%s' \"\${BASH_ENV-unset}\" \"\$SHLVL\" \"\$0\""
                    normal = execute(bash, (; command))
                    timed = execute(bash, (; command, timeout=30))
                    @test timed == normal
                    @test startswith(normal.text, "unset|6|")
                end
                for _ in 1:12
                    @test execute(bash, (; command="printf repeat", timeout=30)) == ToolSuccess("repeat")
                end
                special = joinpath(dir, "gate-\$(touch injected)")
                mkdir(special)
                withenv("TMP" => special, "TEMP" => special, "BASH_ENV" => nothing) do
                    @test execute(bash, (; command="printf complete", timeout=30)) == ToolSuccess("complete")
                    @test !isfile(joinpath(dir, "injected"))
                end
                hook = replace(joinpath(dir, "startup hook 'quoted'.sh"), '\\' => '/')
                write(hook, "printf x >> hook-runs; printf '%s' \"\$BASH_ENV\" > hook-env\n")
                withenv("BASH_ENV" => hook) do
                    @test execute(bash, (; command="printf '%s' \"a 'quoted' \\\"value\\\" 🌱\"", timeout=30)) == ToolSuccess("a 'quoted' \"value\" 🌱")
                    @test read(joinpath(dir, "hook-runs"), String) == "x"
                    @test read(joinpath(dir, "hook-env"), String) == hook
                end

                lowerhook = replace(joinpath(dir, "lowercase startup.sh"), '\\' => '/')
                write(lowerhook, "printf x >> lowercase-runs\n")
                withenv("bash_env" => lowerhook) do
                    @test execute(bash, (; command="printf complete")) == ToolSuccess("complete")
                    before = isfile(joinpath(dir, "lowercase-runs")) ? read(joinpath(dir, "lowercase-runs"), String) : ""
                    @test execute(bash, (; command="printf complete", timeout=30)) == ToolSuccess("complete")
                    after = isfile(joinpath(dir, "lowercase-runs")) ? read(joinpath(dir, "lowercase-runs"), String) : ""
                    @test after == before * before
                end

                withenv("BASH_FUNC_read%%" => "() { printf injected > imported-function-ran; builtin read \"\$@\"; }") do
                    @test execute(bash, (; command="printf user-ran", timeout=30)) == ToolFailure("Could not isolate Bash with exported functions; command was not started")
                    @test !isfile(joinpath(dir, "imported-function-ran"))
                end

                protected = replace(joinpath(dir, "protected startup.sh"), '\\' => '/')
                write(protected, "printf started > startup-ran\n")
                env = copy(ENV)
                env["BASH_ENV"] = protected
                gatefile = JuliaForever.shellgate(bash, env, ShellCancellation(), 30, "printf bad > user-ran")
                @test !occursin(protected, read(gatefile.file, String))
                executable, arguments = JuliaForever.config(bash)
                blocked = Cmd(Cmd([executable; arguments; JuliaForever.shellcommand(bash, "printf bad > user-ran", ShellCancellation(), 30, gatefile)]); dir=dir, env)
                try
                    mktemp() do _, io
                        result = JuliaForever.startshell!(Set{JuliaForever.ShellRun}(), blocked, io, JuliaForever.WindowsJob(C_NULL))
                        @test result == ToolFailure("Could not isolate Windows shell; command was not started")
                    end
                    @test !isfile(joinpath(dir, "startup-ran"))
                    @test !isfile(joinpath(dir, "user-ran"))
                finally
                    JuliaForever.cleanupgate(gatefile)
                end

                env = copy(ENV)
                env["BASH_ENV"] = protected
                gatefile = JuliaForever.shellgate(bash, env, ShellCancellation(), 30, "printf bad > user-ran")
                blocked = Cmd(Cmd([executable; arguments; JuliaForever.shellcommand(bash, "printf bad > user-ran", ShellCancellation(), 30, gatefile)]); dir=dir, env)
                rm(gatefile.file)
                try
                    mktemp() do _, io
                        result = JuliaForever.startshell!(Set{JuliaForever.ShellRun}(), blocked, io, ShellCancellation(), 30, gatefile)
                        @test result == ToolFailure("Could not isolate Windows shell; command was not started")
                    end
                    @test !isfile(joinpath(dir, "startup-ran"))
                    @test !isfile(joinpath(dir, "user-ran"))
                finally
                    JuliaForever.cleanupgate(gatefile)
                end

                env = copy(ENV)
                env["BASH_ENV"] = protected
                gatefile = JuliaForever.shellgate(bash, env, ShellCancellation(), 30, "printf bad > user-ran")
                blocked = Cmd(Cmd([executable; arguments; JuliaForever.shellcommand(bash, "printf bad > user-ran", ShellCancellation(), 30, gatefile)]); dir=dir, env)
                job = JuliaForever.windowsjob()
                pipe = Pipe()
                other = unrelated(shell)
                mktemp() do _, io
                    process = run(pipeline(ignorestatus(blocked); stdin=pipe, stdout=io, stderr=io); wait=false)
                    close(pipe.out)
                    try
                        @test timedwait(() -> JuliaForever.gatepid(gatefile) > 0 || process_exited(process), 15; pollint=0.05) == :ok
                        pid = JuliaForever.gatepid(gatefile)
                        @test pid > 0
                        @test JuliaForever.assign(job, process)
                        rootpid = UInt(ccall(:jl_uv_process_pid, Cint, (Ptr{Cvoid},), process.handle))
                        if pid == rootpid
                            @test JuliaForever.checkgate(job, process, gatefile, 1) === nothing
                        else
                            @test JuliaForever.checkgate(job, process, gatefile, 1) == ToolFailure("Could not isolate Windows shell; command was not started")
                        end
                        @test process_running(other)
                        @test !isfile(joinpath(dir, "startup-ran"))
                        @test !isfile(joinpath(dir, "user-ran"))
                    finally
                        close(pipe)
                        timedwait(() -> process_exited(process), 10; pollint=0.05)
                        process_running(process) && kill(process)
                        wait(process)
                        JuliaForever.closejob(job)
                        process_running(other) && kill(other)
                        wait(other)
                        JuliaForever.cleanupgate(gatefile)
                    end
                end

                hookchild = raw"""[IO.File]::WriteAllText('hook-child', [string]$PID); [IO.File]::WriteAllText('hook-ready', 'ready'); while (!(Test-Path -LiteralPath 'hook-release')) { Start-Sleep -Milliseconds 50 }; [IO.File]::WriteAllText('hook-late', 'late')"""
                write(hook, "printf hook-before; powershell.exe -NoProfile -NonInteractive -Command " * bashquote(hookchild) * " & wait\n")
                withenv("BASH_ENV" => hook) do
                    token = ShellCancellation()
                    running = Threads.@spawn execute(bash, (; command="printf user-ran", timeout=30); cancel=token)
                    try
                        ready = timedwait(() -> isfile(joinpath(dir, "hook-ready")) || istaskdone(running), 15; pollint=0.05)
                        @test ready == :ok
                        @test isfile(joinpath(dir, "hook-ready"))
                        if isfile(joinpath(dir, "hook-ready"))
                            pid = parse(UInt32, read(joinpath(dir, "hook-child"), String))
                            job = lock(token.lock) do
                                only(token.runs).job
                            end
                            @test pid in members(job)
                            cancel!(token)
                            finished = timedwait(() -> istaskdone(running), 10; pollint=0.05)
                            @test finished == :ok
                            if finished == :ok
                                @test fetch(running) == ToolFailure("hook-before\n\nCommand aborted")
                                @test timedwait(() -> !alive(pid), 5; pollint=0.05) == :ok
                            end
                        end
                    finally
                        cancel!(token)
                        write(joinpath(dir, "hook-release"), "release")
                    end
                    @test !isfile(joinpath(dir, "hook-late"))
                end

                @test execute(bash, (; command="printf complete", timeout=30)) == ToolSuccess("complete")
                timed = execute(bash, (; command="printf before; sleep 30", timeout=4))
                @test timed == ToolFailure("before\n\nCommand timed out after 4 seconds")
                token = ShellCancellation()
                descendant = raw"""[IO.File]::WriteAllText('bash-child', [string]$PID); [IO.File]::WriteAllText('bash-ready', 'ready'); while (!(Test-Path -LiteralPath 'bash-release')) { Start-Sleep -Milliseconds 50 }; [IO.File]::WriteAllText('bash-late', 'late')"""
                command = "printf before; powershell.exe -NoProfile -NonInteractive -Command " * bashquote(descendant) * " & wait"
                running = Threads.@spawn execute(bash, (; command, timeout=30); cancel=token)
                try
                    ready = timedwait(() -> isfile(joinpath(dir, "bash-ready")) || istaskdone(running), 15; pollint=0.05)
                    @test ready == :ok
                    @test isfile(joinpath(dir, "bash-ready"))
                    if isfile(joinpath(dir, "bash-ready"))
                        pid = parse(UInt32, read(joinpath(dir, "bash-child"), String))
                        job = lock(token.lock) do
                            only(token.runs).job
                        end
                        @test pid in members(job)
                        cancel!(token)
                        finished = timedwait(() -> istaskdone(running), 10; pollint=0.05)
                        @test finished == :ok
                        if finished == :ok
                            @test fetch(running) == ToolFailure("before\n\nCommand aborted")
                            @test timedwait(() -> !alive(pid), 5; pollint=0.05) == :ok
                        end
                    end
                finally
                    cancel!(token)
                    write(joinpath(dir, "bash-release"), "release")
                end
            end

            owner = fixture(dir, "owner")
            commandfile = joinpath(dir, "owner-command")
            write(commandfile, owner.command)
            script = joinpath(@__DIR__, "system_windows_owner.jl")
            project = dirname(@__DIR__)
            cmd = `$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project $script $dir $commandfile`
            worker = run(pipeline(ignorestatus(cmd); stdin=devnull, stdout=devnull, stderr=devnull); wait=false)
            other = unrelated(shell)
            try
                ready = timedwait(() -> isfile(owner.ready) || process_exited(worker), 40; pollint=0.05)
                @test ready == :ok
                @test isfile(owner.ready)
                if isfile(owner.ready)
                    pids = parse.(UInt32, read.((owner.leader, owner.child, owner.grandchild), String))
                    kill(worker, Base.SIGKILL)
                    wait(worker)
                    @test timedwait(() -> all(pid -> !alive(pid), pids), 10; pollint=0.05) == :ok
                    @test process_running(other)
                    write(owner.release, "release")
                    sleep(0.5)
                    @test !isfile(owner.late)
                end
            finally
                process_running(worker) && kill(worker, Base.SIGKILL)
                wait(worker)
                process_running(other) && kill(other)
                wait(other)
                write(owner.release, "release")
            end

            independent = [fixture(dir, "independent-$i") for i in 1:2]
            tokens = [ShellCancellation(), ShellCancellation()]
            jobs = [Threads.@spawn execute(shell, (; command=independent[i].command, timeout=30); cancel=tokens[i]) for i in 1:2]
            try
                ready = timedwait(() -> all(current -> isfile(current.ready), independent) || any(istaskdone, jobs), 20; pollint=0.05)
                @test ready == :ok
                @test all(current -> isfile(current.ready), independent)
                if all(current -> isfile(current.ready), independent)
                    cancel!(tokens[1])
                    stopped = timedwait(() -> istaskdone(jobs[1]), 10; pollint=0.05)
                    @test stopped == :ok
                    stopped == :ok && @test fetch(jobs[1]) == ToolFailure("before\n\nCommand aborted")
                    @test !istaskdone(jobs[2])
                    write(independent[2].release, "release")
                    finished = timedwait(() -> istaskdone(jobs[2]), 10; pollint=0.05)
                    @test finished == :ok
                    finished == :ok && @test fetch(jobs[2]) == ToolSuccess("before")
                    @test isfile(independent[2].late)
                end
            finally
                foreach(cancel!, tokens)
                foreach(current -> write(current.release, "release"), independent)
            end

            fixtures = [fixture(dir, "agent-$i") for i in 1:2]
            provider = WindowsProvider(Any[reply(fixtures), Dict("role" => "assistant", "content" => "unexpected")])
            agent = Agent(provider, [shell])
            running = Threads.@spawn respond!(agent, "run"; tool_execution=:parallel)
            try
                ready = timedwait(() -> all(current -> isfile(current.ready), fixtures) || istaskdone(running), 20; pollint=0.05)
                @test ready == :ok
                @test all(current -> isfile(current.ready), fixtures)
                if all(current -> isfile(current.ready), fixtures)
                    pids = [parse.(UInt32, read.((current.leader, current.child, current.grandchild), String)) for current in fixtures]
                    @test cancel!(agent) === true
                    finished = timedwait(() -> istaskdone(running), 10; pollint=0.05)
                    @test finished == :ok
                    if finished == :ok
                        @test fetch(running) == :cancelled
                        @test timedwait(() -> all(ids -> all(pid -> !alive(pid), ids), pids), 5; pollint=0.05) == :ok
                    end
                end
            finally
                cancel!(agent)
                foreach(current -> write(current.release, "release"), fixtures)
            end
        end
    end
end

if Sys.iswindows() && haskey(ENV, "PI_SOURCE")
    @testset "Windows shells against pinned Pi" begin
        @test readchomp(`git -C $(ENV["PI_SOURCE"]) rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
        bashenabled = isnothing(JuliaForever.config(Bash(pwd()))) ? "powershell" : "bash"
        reference = JSON3.read(read(`node --conditions=source --experimental-strip-types $(joinpath(@__DIR__, "system_windows_reference.mjs")) $(ENV["PI_SOURCE"]) $bashenabled`, String))
        mktempdir() do dir
            shell = PowerShell(dir)
            normal = execute(shell, (; command="[Console]::Write('complete')"))
            @test (normal.text, normal.iserror) == (reference[1].text, reference[1].iserror)
            timed = execute(shell, (; command="[Console]::Write('before'); [Console]::Out.Flush(); Start-Sleep -Seconds 30", timeout=4))
            @test (timed.text, timed.iserror) == (reference[2].text, reference[2].iserror)
            token = ShellCancellation()
            run = Threads.@spawn execute(shell, (; command="[Console]::Write('before'); [Console]::Out.Flush(); [IO.File]::WriteAllText('ready','ready'); Start-Sleep -Seconds 30"); cancel=token)
            try
                @test timedwait(() -> isfile(joinpath(dir, "ready")) || istaskdone(run), 15; pollint=0.05) == :ok
                @test isfile(joinpath(dir, "ready"))
                if isfile(joinpath(dir, "ready"))
                    cancel!(token)
                    @test timedwait(() -> istaskdone(run), 10; pollint=0.05) == :ok
                    if istaskdone(run)
                        cancelled = fetch(run)
                        @test (cancelled.text, cancelled.iserror) == (reference[3].text, reference[3].iserror)
                    end
                end
            finally
                cancel!(token)
            end
            if bashenabled == "bash"
                bash = Bash(dir)
                normal = execute(bash, (; command="printf complete", timeout=30); cancel=ShellCancellation())
                @test (normal.text, normal.iserror) == (reference[4].text, reference[4].iserror)
                timed = execute(bash, (; command="printf before; printf ready > bash-ready; sleep 30", timeout=4))
                @test (timed.text, timed.iserror) == (reference[5].text, reference[5].iserror)
                token = ShellCancellation()
                running = Threads.@spawn execute(bash, (; command="printf before; printf ready > bash-cancel-ready; sleep 30"); cancel=token)
                try
                    @test timedwait(() -> isfile(joinpath(dir, "bash-cancel-ready")) || istaskdone(running), 15; pollint=0.05) == :ok
                    @test isfile(joinpath(dir, "bash-cancel-ready"))
                    if isfile(joinpath(dir, "bash-cancel-ready"))
                        cancel!(token)
                        finished = timedwait(() -> istaskdone(running), 10; pollint=0.05)
                        @test finished == :ok
                        if finished == :ok
                            cancelled = fetch(running)
                            @test (cancelled.text, cancelled.iserror) == (reference[6].text, reference[6].iserror)
                        end
                    end
                finally
                    cancel!(token)
                end
            end
        end
    end
end

end
