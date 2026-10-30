@testset "shell streaming" begin
    if !Sys.iswindows()
        mktempdir() do dir
            shell = Bash(dir)
            updates = ShellUpdate[]
            command = "for ((i=1;i<=2001;i++)); do echo \$i; done; while [ ! -f release ]; do sleep .02; done"
            result = execute(shell, (; command, timeout=5); on_update=update -> begin
                push!(updates, update)
                endswith(update.text, "2001") && write(joinpath(dir, "release"), "")
            end)
            @test first(updates).text == ""
            @test isnothing(first(updates).file)
            @test last(updates).text == join(2:2001, '\n')
            file = last(updates).file
            @test !isnothing(file)
            @test read(file, String) == join(1:2001, '\n') * "\n"
            @test occursin("Full output: $file", result.text)
            rm(file; force=true)

            empty!(updates)
            rm(joinpath(dir, "release"))
            command = "printf '%051201d' 0; while [ ! -f release ]; do sleep .02; done"
            result = execute(shell, (; command, timeout=5); on_update=update -> begin
                push!(updates, update)
                !isnothing(update.file) && write(joinpath(dir, "release"), "")
            end)
            @test last(updates).text == repeat("0", 51200)
            file = last(updates).file
            @test !isnothing(file)
            @test read(file, String) == repeat("0", 51201)
            @test occursin("Full output: $file", result.text)
            rm(file; force=true)

            empty!(updates)
            token = ShellCancellation()
            command = "printf before; sleep 30; touch late"
            result = execute(shell, (; command, timeout=5); cancel=token, on_update=update -> begin
                push!(updates, update)
                update.text == "before" && cancel!(token)
            end)
            @test [update.text for update in updates] == ["", "before"]
            @test result == ToolFailure("before\n\nCommand aborted")
            @test !isfile(joinpath(dir, "late"))
            @test execute(shell, (; command="touch unexpected"); cancel=token) == ToolFailure("Command aborted")
            @test !isfile(joinpath(dir, "unexpected"))

            empty!(updates)
            result = execute(shell, (; command="printf before; sleep 30", timeout=0.25); on_update=update -> push!(updates, update))
            @test [update.text for update in updates] == ["", "before"]
            @test result == ToolFailure("before\n\nCommand timed out after 0.25 seconds")

            empty!(updates)
            result = execute(shell, (; command="printf '\\360\\237'; sleep .3; printf '\\214\\261'", timeout=5); on_update=update -> push!(updates, update))
            @test all(update -> isvalid(update.text), updates)
            @test last(updates).text == "🌱"
            @test result == ToolSuccess("🌱")

            empty!(updates)
            result = execute(shell, (; command="printf '\\360\\237'; sleep .3", timeout=5); on_update=update -> push!(updates, update))
            @test all(update -> isvalid(update.text), updates)
            @test last(updates).text == "�"
            @test result == ToolSuccess("�")

            empty!(updates)
            command = "head -c 20000 /dev/zero | LC_ALL=C tr '\\000' '\\377'; while [ ! -f malformed-release ]; do sleep .02; done"
            result = execute(shell, (; command, timeout=5); on_update=update -> begin
                push!(updates, update)
                (ncodeunits(update.text) > 51200 || !isnothing(update.file)) && write(joinpath(dir, "malformed-release"), "")
            end)
            @test ncodeunits(last(updates).text) <= 51200
            file = last(updates).file
            @test !isnothing(file)
            if !isnothing(file)
                @test read(file) == fill(0xff, 20000)
                @test occursin("Full output: $file", result.text)
                rm(file; force=true)
            end

            empty!(updates)
            token = ShellCancellation()
            cancel!(token)
            result = execute(shell, (; command="touch unexpected"); cancel=token, on_update=update -> push!(updates, update))
            @test [update.text for update in updates] == [""]
            @test result == ToolFailure("Command aborted")
            @test !isfile(joinpath(dir, "unexpected"))

            token = ShellCancellation()
            command = "printf '%s' \"\$\$\" > pid; printf before; sleep 30; touch late"
            @test_throws ErrorException execute(shell, (; command, timeout=5); cancel=token, on_update=update -> begin
                update.text == "before" && error("callback failed")
            end)
            pid = parse(Int, read(joinpath(dir, "pid"), String))
            @test timedwait(() -> ccall(:kill, Cint, (Cint, Cint), pid, 0) == -1 && Base.Libc.errno() == Base.Libc.ESRCH, 5) == :ok
            @test execute(shell, (; command="printf after"); cancel=token) == ToolSuccess("after")
            @test !isfile(joinpath(dir, "late"))

            file = Ref{Union{Nothing, String}}(nothing)
            command = "printf '%051201d' 0; sleep 30"
            @test_throws ErrorException execute(shell, (; command, timeout=5); on_update=update -> begin
                if !isnothing(update.file)
                    file[] = update.file
                    error("callback failed")
                end
            end)
            @test !isnothing(file[])
            @test read(file[], String) == repeat("0", 51201)
            rm(file[]; force=true)
        end
    end
end
