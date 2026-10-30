@testset "Pi shell streaming" begin
    @test readchomp(`git -C $(ENV["PI_SOURCE"]) rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    if !Sys.iswindows()
        mktempdir() do dir
            oracle = joinpath(dir, "oracle")
            mkdir(oracle)
            command = `node $(joinpath(@__DIR__, "system_stream_reference.mjs")) $(ENV["PI_SOURCE"])`
            reference = JSON3.read(read(addenv(command, "PI_CODING_AGENT_DIR" => oracle), String))
            @test reference.updates == ["", "first\n", "first\nsecond\n"]
            updates = String[]
            result = execute(Bash(dir), (; command="printf 'first\\n'; while [ ! -f release ]; do sleep .02; done; printf 'second\\n' >&2", timeout=5); on_update=update -> begin
                push!(updates, update.text)
                update.text == "first\n" && write(joinpath(dir, "release"), "")
            end)
            @test updates == reference.updates
            @test result == ToolSuccess(reference.result)
        end
    end
end
