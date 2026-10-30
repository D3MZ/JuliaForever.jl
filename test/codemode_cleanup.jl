using Test, JuliaForever

@testset "code worker cleanup" begin
    unlimited = CodeMode(JuliaForever.Tool[]; timeout=Inf)
    result = codeexecute(unlimited, "text(\"ready\"); 42")
    @test result isa CodeSuccess && result.value == 42 && result.output == ["ready"]
    @test result.pid > 0
    if Sys.isunix()
        @test ccall(:kill, Cint, (Cint, Cint), result.pid, 0) == -1
    end

    expired = codeexecute(CodeMode(JuliaForever.Tool[]; timeout=0), "error(\"not run\")")
    @test expired isa CodeFailure && expired.kind == :timeout && expired.pid == 0

    mktempdir() do dir
        marker = joinpath(dir, "started")
        cancellation = CodeCancellation()
        task = Threads.@spawn codeexecute(unlimited, "write($(repr(marker)), \"ready\"); sleep(60)"; cancel=cancellation)
        ready = timedwait(() -> isfile(marker), 45)
        @test ready == :ok
        cancel!(cancellation)
        cancelled = fetch(task)
        @test cancelled isa CodeFailure && cancelled.kind == :cancelled && cancelled.pid > 0
        if Sys.isunix() && cancelled.pid > 0
            @test ccall(:kill, Cint, (Cint, Cint), cancelled.pid, 0) == -1
        end
    end
end
