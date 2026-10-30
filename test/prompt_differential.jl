using Test, JSON3

@testset "Pi prompt templates through the terminal" begin
    source = ENV["PI_SOURCE"]
    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    mktempdir() do path
        root = realpath(path)
        agentdir = joinpath(root, "agent")
        cwd = joinpath(root, "project")
        globalprompts = joinpath(agentdir, "prompts")
        projectprompts = joinpath(cwd, ".pi", "prompts")
        mkpath.((globalprompts, projectprompts))
        write(joinpath(globalprompts, "review.md"), "---\ndescription: Review changes\nargument-hint: '[focus]'\n---\nReview \$1 | \${2:-everything} | \$@")
        write(joinpath(globalprompts, "same.md"), "global \$1")
        write(joinpath(projectprompts, "same.md"), "project \$1")
        write(joinpath(projectprompts, "slice.md"), "Args: \${@:2} | \${@:2:1} | \${@:-none} | \$ARGUMENTS")
        write(joinpath(projectprompts, "invalid.md"), "---\ndescription: [\n---\nignored")
        mkpath(joinpath(projectprompts, "nested"))
        write(joinpath(projectprompts, "nested", "hidden.md"), "not discovered")
        prompts = ["/review \"front end\"", "/review", "/review '\$1'", "/review \"unfinished quote", "/slice '' 'two words' three", "/same value", "/invalid", "/hidden", "/unknown command"]
        input = joinpath(root, "reference.json")
        write(input, JSON3.write((; cwd, agentDir=agentdir, prompts)))
        reference = JSON3.read(read(`node $(joinpath(@__DIR__, "prompt_reference.mjs")) $source $input`, String))
        stdinpath = joinpath(root, "stdin")
        output = joinpath(root, "output")
        diagnostics = joinpath(root, "diagnostics")
        write(stdinpath, join([prompts; "/exit"], "\n") * "\n")
        project = dirname(@__DIR__)
        cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project $(joinpath(@__DIR__, "terminal_process.jl")) --no-session`; dir=cwd)
        cmd = addenv(cmd, "PI_CODING_AGENT_DIR" => agentdir, "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "synthetic-secret", "JF_FIXTURE" => "reply")
        process = run(pipeline(ignorestatus(cmd); stdin=stdinpath, stdout=output, stderr=diagnostics))
        @test process.exitcode == 0
        @test all(path -> occursin(path, read(diagnostics, String)), reference.diagnostics)
        @test read(output, String) == join(("reply:" * prompt * "\n" for prompt in reference.expanded))
        oneshot = Cmd(`$cmd $(prompts[1])`; dir=cwd)
        @test read(pipeline(oneshot; stderr=devnull), String) == "reply:$(reference.expanded[1])\n"
    end
end
