function shellfixture(dir, id)
    gate = "gate-$id"
    run(`mkfifo $(joinpath(dir, gate))`)
    write(joinpath(dir, "grandchild-$id.sh"), "printf '%s' \"\$\$\" > grandchild-$id\nprintf ready > ready-$id\nread -r < $gate\nprintf late > late-$id\n")
    write(joinpath(dir, "child-$id.sh"), "printf '%s' \"\$\$\" > child-$id\nbash grandchild-$id.sh &\nwait\n")
    "printf '%s' \"\$\$\" > leader-$id; printf before; bash child-$id.sh & wait"
end

function shellpids(dir, id)
    [parse(Int, read(joinpath(dir, "$name-$id"), String)) for name in ("leader", "child", "grandchild")]
end

function gone(pid)
    ccall(:kill, Cint, (Cint, Cint), pid, 0) == -1 && Base.Libc.errno() == Base.Libc.ESRCH
end

@testset "shell outcome messages" begin
    @test JuliaForever.shellresult(JuliaForever.ShellStopFailed(), "before", nothing, nothing) == ToolFailure("before\n\nCould not stop shell process group; the command may still be running")
end

@testset "shell cancellation" begin
    if Sys.iswindows()
        mktempdir() do dir
            result = execute(Bash(dir), (; command="echo unexpected"); cancel=JuliaForever.ShellCancellation())
            @test result == ToolResult("Cancellation is not supported on Windows", true)
        end
    else
        mktempdir() do dir
            shell = Bash(dir)
            cancel = JuliaForever.ShellCancellation()
            cancel!(cancel)
            cancel!(cancel)
            @test execute(shell, (; command="touch unexpected"); cancel) == ToolResult("Command aborted", true)
            @test !isfile(joinpath(dir, "unexpected"))

            cancel = JuliaForever.ShellCancellation()
            @test execute(shell, (; command="printf complete"); cancel) == ToolResult("complete")
            cancel!(cancel)
            @test execute(shell, (; command="touch unexpected"); cancel) == ToolResult("Command aborted", true)
            @test !isfile(joinpath(dir, "unexpected"))

            cancel = JuliaForever.ShellCancellation()
            @test execute(shell, (; command="printf complete", timeout=0.2); cancel) == ToolResult("complete")
            command = shellfixture(dir, "next")
            run = Threads.@spawn execute(shell, (; command, timeout=60); cancel)
            try
                @test timedwait(() -> isfile(joinpath(dir, "ready-next")), 5) == :ok
                pids = shellpids(dir, "next")
                @test timedwait(() -> istaskdone(run), 0.4) == :timed_out
                cancel!(cancel)
                @test timedwait(() -> istaskdone(run), 5) == :ok
                @test fetch(run) == ToolResult("before\n\nCommand aborted", true)
                @test timedwait(() -> all(gone, pids) && gone(-first(pids)), 5) == :ok
            finally
                cancel!(cancel)
                wait(run)
            end

            cancel = JuliaForever.ShellCancellation()
            commands = [shellfixture(dir, i) for i in 1:2]
            runs = [Threads.@spawn execute(shell, (; command); cancel) for command in commands]
            try
                @test timedwait(() -> all(i -> isfile(joinpath(dir, "ready-$i")), 1:2), 10) == :ok
                pids = [shellpids(dir, i) for i in 1:2]
                @test all(ids -> all(pid -> ccall(:getpgid, Cint, (Cint,), pid) == first(ids), ids), pids)
                elapsed = @elapsed begin
                    cancel!(cancel)
                    cancel!(cancel)
                    @test all(task -> timedwait(() -> istaskdone(task), 5) == :ok, runs)
                    @test all(task -> fetch(task) == ToolResult("before\n\nCommand aborted", true), runs)
                end
                @test elapsed < 5
                @test timedwait(() -> all(ids -> all(gone, ids) && gone(-first(ids)), pids), 5) == :ok
                @test all(i -> !isfile(joinpath(dir, "late-$i")), 1:2)
            finally
                cancel!(cancel)
                foreach(wait, runs)
            end

            cancel = JuliaForever.ShellCancellation()
            command = shellfixture(dir, "timeout")
            run = Threads.@spawn execute(shell, (; command, timeout=2); cancel)
            try
                @test timedwait(() -> isfile(joinpath(dir, "ready-timeout")), 5) == :ok
                pids = shellpids(dir, "timeout")
                @test timedwait(() -> istaskdone(run), 6) == :ok
                @test fetch(run) == ToolResult("before\n\nCommand timed out after 2 seconds", true)
                cancel!(cancel)
                @test timedwait(() -> all(gone, pids) && gone(-first(pids)), 5) == :ok
                @test !isfile(joinpath(dir, "late-timeout"))
            finally
                cancel!(cancel)
                wait(run)
            end

            for _ in 1:30
                cancel = JuliaForever.ShellCancellation()
                run = Threads.@spawn execute(shell, (; command="printf complete", timeout=0.01); cancel)
                cancel!(cancel)
                @test timedwait(() -> istaskdone(run), 5) == :ok
                result = fetch(run)
                @test result in (ToolResult("complete"), ToolResult("Command aborted", true), ToolResult("complete\n\nCommand aborted", true), ToolResult("Command timed out after 0.01 seconds", true), ToolResult("complete\n\nCommand timed out after 0.01 seconds", true))
                @test execute(shell, (; command="touch unexpected"); cancel) == ToolFailure("Command aborted")
                @test !isfile(joinpath(dir, "unexpected"))
            end
        end
    end
end
