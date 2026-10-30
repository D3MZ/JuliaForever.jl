@testset "shell option dispatch" begin
    calls = Ref(0)
    next() = (calls[] += 1; "fallback")
    @test JuliaForever.fallback("existing", next) == "existing" && calls[] == 0
    @test JuliaForever.fallback(nothing, next) == "fallback" && calls[] == 1
    @test JuliaForever.shellconfig(nothing, ["-c"]) === nothing
    @test JuliaForever.shellconfig("bash", ["-c"]) == ("bash", ["-c"])
    @test JuliaForever.timeoutcheck(nothing) === nothing
    @test JuliaForever.timeoutcheck(0) isa ToolFailure
    @test JuliaForever.timeoutcheck(Inf) isa ToolFailure
    @test JuliaForever.timeoutcheck(2147484) isa ToolFailure
    @test JuliaForever.windowoptions(nothing, nothing) === nothing
    @test occursin("Timeout", JuliaForever.windowoptions(1, ShellCancellation()).text)
    @test occursin("Cancellation", JuliaForever.windowoptions(nothing, ShellCancellation()).text)
end

@testset "shell and directory tools" begin
    mktempdir() do dir
        shell = Bash(dir)
        listing = Ls(dir)
        @test execute(listing, (;)).text == "(empty directory)"
        write(joinpath(dir, "beta.txt"), "b")
        write(joinpath(dir, ".hidden"), "h")
        mkpath(joinpath(dir, "alpha"))
        @test execute(listing, (;)).text == ".hidden\nalpha/\nbeta.txt"
        @test execute(listing, (; limit=2)).text == ".hidden\nalpha/\n\n[2 entries limit reached. Use limit=4 for more]"
        @test execute(listing, (; path="missing")).iserror
        @test execute(listing, (; path="beta.txt")).iserror
        mkdir(joinpath(dir, "long"))
        for i in 1:210
            write(joinpath(dir, "long", lpad(i, 3, '0') * repeat("x", 245)), "")
        end
        long = execute(listing, (; path="long"))
        @test endswith(long.text, "\n\n[50.0KB limit reached]")
        @test all(line -> length(line) == 248, split(first(split(long.text, "\n\n")), '\n'))
        @test execute(Bash(joinpath(dir, "missing")), (; command="printf no")).iserror

        if !Sys.iswindows()
            @test execute(shell, (; command="printf 'hello 🌱'")) == ToolResult("hello 🌱")
            @test execute(shell, (; command="printf 'warning' >&2")) == ToolResult("warning")
            @test execute(shell, (; command="true")) == ToolResult("(no output)")
            failed = execute(shell, (; command="printf fail; exit 7"))
            @test failed == ToolResult("fail\n\nCommand exited with code 7", true)
            @test execute(shell, (; command="pwd")).text == realpath(dir) * "\n"
            withenv("PI_SESSION_ID" => "secret") do
                @test execute(shell, (; command="printf '%s' \"\${PI_SESSION_ID:-unset}\"")).text == "unset"
            end
            timed = execute(shell, (; command="printf before; sleep 1; touch late", timeout=0.1))
            @test timed == ToolResult("before\n\nCommand timed out after 0.1 seconds", true)
            sleep(1.1)
            @test !isfile(joinpath(dir, "late"))
            @test execute(shell, (; command="true", timeout=0)).iserror
            large = execute(shell, (; command="for ((i=1; i<=2001; i++)); do echo \"\$i\"; done"))
            @test !large.iserror
            @test startswith(large.text, "2\n3\n")
            outputpath = match(r"Full output: (.+)\]$", large.text)
            @test !isnothing(outputpath)
            if !isnothing(outputpath)
                @test read(outputpath.captures[1], String) == join(1:2001, '\n') * "\n"
                rm(outputpath.captures[1]; force=true)
            end
            @test execute(PowerShell(dir), (; command="Write-Output hello")).iserror
        else
            @test execute(PowerShell(dir), (; command="Write-Output hello", timeout=1)).iserror
            @test execute(Bash(dir), (; command="true", timeout=1)).iserror
            @test replace(execute(PowerShell(dir), (; command="Write-Output hello")).text, "\r\n" => "\n") == "hello\n"
        end
    end
end

include("system_cancel.jl")
include("system_agent_cancel.jl")
include("system_stream.jl")
