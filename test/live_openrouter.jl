# Opt-in live smoke test. Set JF_LIVE_OPENROUTER_MODEL to a current :free model
# (or openrouter/free) and configure an OpenRouter key before running this file.
using Test, JuliaForever

@testset "live OpenRouter CLI and session" begin
    model = ENV["JF_LIVE_OPENROUTER_MODEL"]
    @test endswith(model, ":free") || model == "openrouter/free"
    if endswith(model, ":free") || model == "openrouter/free"
        mktempdir() do root
            project = dirname(@__DIR__)
            session = joinpath(root, "session.sqlite")
            agentdir = get(ENV, "PI_CODING_AGENT_DIR", joinpath(homedir(), ".pi", "agent"))
            cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project -m JuliaForever --provider openrouter --model $model --history $session`; dir=root)
            cmd = addenv(cmd, "HOME" => root, "PI_CODING_AGENT_DIR" => agentdir, "JF_INSTRUCTIONS_DIR" => root)
            first = read(`$cmd $("Create notes.txt containing only violet harbor, then read the file and report its contents.")`, String)
            @test isfile(joinpath(root, "notes.txt"))
            @test strip(read(joinpath(root, "notes.txt"), String)) == "violet harbor"
            @test occursin("violet", lowercase(first))
            second = read(`$cmd $("What color was in my previous request? Reply with the color.")`, String)
            @test occursin("violet", lowercase(second))
        end
    end
end
