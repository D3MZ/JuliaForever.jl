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

if Sys.iswindows() && haskey(ENV, "PI_SOURCE")
    @testset "Windows shells against pinned Pi" begin
        @test readchomp(`git -C $(ENV["PI_SOURCE"]) rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
        bashenabled = isnothing(JuliaForever.config(Bash(pwd()))) ? "powershell" : "bash"
        reference = JSON3.read(read(`node --conditions=source --experimental-strip-types $(joinpath(@__DIR__, "system_windows_reference.mjs")) $(ENV["PI_SOURCE"]) $bashenabled`, String))
        @test reference[end].background === true
        @test reference[end].text == "complete"
        mktempdir() do dir
            shell = PowerShell(dir)
            malformed = "[IO.File]::WriteAllText('unreachable','bad'); if ("
            updates = ShellUpdate[]
            syntax = execute(shell, (; command=malformed, timeout=30); cancel=ShellCancellation(), on_update=update -> push!(updates, update))
            @test syntax.iserror
            @test !isfile(joinpath(dir, "unreachable"))
            @test [update.text for update in updates] == reference[end - 1].updates
            @test (syntax.text, syntax.iserror) == (reference[end - 1].text, reference[end - 1].iserror)
            cancelled = ShellCancellation()
            cancel!(cancelled)
            @test execute(shell, (; command=malformed, timeout=30); cancel=cancelled) == ToolFailure("Command aborted")
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
                for (index, options) in enumerate(("xtrace", "verbose", "verbose:xtrace", "posix", "noexec", "posix:verbose:xtrace", "noexec:verbose:xtrace", "posix:noexec:verbose:xtrace", "allexport:noclobber", "privileged:xtrace"))
                    withenv("SHELLOPTS" => options, "BASHOPTS" => nothing, "BASH_ENV" => nothing, "BASH_XTRACEFD" => nothing, "PS4" => "+ ") do
                        traced = execute(bash, (; command="printf complete >&2", timeout=30); cancel=ShellCancellation())
                        @test (traced.text, traced.iserror) == (reference[end - 2].cases[index].text, reference[end - 2].cases[index].iserror)
                        @test !occursin("JF_BASH_GATE_", traced.text)
                    end
                end
                for (index, (shell, options)) in enumerate(((nothing, "extdebug"), (nothing, "expand_aliases"), (nothing, "failglob"), (nothing, "extdebug:expand_aliases"), ("posix:xtrace", "extdebug:expand_aliases")))
                    withenv("SHELLOPTS" => shell, "BASHOPTS" => options, "BASH_ENV" => nothing, "BASH_XTRACEFD" => nothing, "PS4" => "+ ") do
                        result = execute(bash, (; command="printf complete >&2", timeout=30); cancel=ShellCancellation())
                        @test (result.text, result.iserror) == (reference[end - 2].bashcases[index].text, reference[end - 2].bashcases[index].iserror)
                    end
                end
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
