@testset "Pi shell cancellation" begin
    @test readchomp(`git -C $(ENV["PI_SOURCE"]) rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    if !Sys.iswindows()
        mktempdir() do dir
            oracle = joinpath(dir, "oracle")
            mkdir(oracle)
            command = `node $(joinpath(@__DIR__, "system_cancel_reference.mjs")) $(ENV["PI_SOURCE"])`
            reference = JSON3.read(read(addenv(command, "PI_CODING_AGENT_DIR" => oracle), String))
            shell = Bash(dir)
            token = ShellCancellation()
            cancel!(token)
            before = execute(shell, (; command="touch unexpected"); cancel=token)
            @test (before.text, before.iserror) == (reference[1].text, reference[1].iserror)
            @test !isfile(joinpath(dir, "unexpected"))

            token = ShellCancellation()
            run = Threads.@spawn execute(shell, (; command="printf before; printf ready > ready; sleep 30; touch late"); cancel=token)
            try
                @test timedwait(() -> isfile(joinpath(dir, "ready")), 10) == :ok
                cancel!(token)
                @test timedwait(() -> istaskdone(run), 5) == :ok
                result = fetch(run)
                @test (result.text, result.iserror) == (reference[2].text, reference[2].iserror)
                @test !isfile(joinpath(dir, "late"))
            finally
                cancel!(token)
                wait(run)
            end
        end
    end
end
