using Test, JuliaForever, JSON3

@testset "terminal compaction survives process restart" begin
    mktempdir() do root
        workspace = joinpath(root, "project")
        sessions = joinpath(root, "sessions")
        requests = joinpath(root, "requests.jsonl")
        input = joinpath(root, "input")
        output = joinpath(root, "output")
        diagnostics = joinpath(root, "diagnostics")
        mkpath(workspace)
        skilldir = joinpath(workspace, ".pi", "skills", "example")
        mkpath(skilldir)
        write(joinpath(skilldir, "SKILL.md"), "---\nname: example\ndescription: local skill metadata\n---\nprivate body\n")
        project = dirname(@__DIR__)
        script = joinpath(@__DIR__, "compaction_cli_process.jl")
        function runcli(args, text)
            write(input, text)
            cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --project=$project $script $args`; dir=workspace)
            cmd = addenv(cmd, "JF_COMPACTION_REQUESTS" => requests, "JF_SESSION_DIR" => sessions, "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "fixture", "JF_INSTRUCTIONS_DIR" => nothing, "HOME" => root, "JULIA_DEPOT_PATH" => join(DEPOT_PATH, Sys.iswindows() ? ';' : ':'), "PI_CODING_AGENT_DIR" => joinpath(root, "agent"))
            process = run(pipeline(ignorestatus(cmd); stdin=input, stdout=output, stderr=diagnostics))
            (; status=process.exitcode, output=read(output, String), diagnostics=read(diagnostics, String))
        end

        first = runcli(String[], "first\nsecond\n/compact\n/exit\n")
        @test first.status == 0
        @test first.output == "reply:first\nreply:second\n"
        @test occursin("Context compacted.", first.diagnostics)
        second = runcli(["--continue", "third"], "")
        @test second.status == 0
        @test second.output == "reply:third\n"
        calls = [JSON3.read(line, Dict{String, Any}) for line in eachline(requests)]
        @test [call["operation"] for call in calls] == ["respond", "respond", "summarize", "respond"]
        @test calls[3]["tool_count"] == 0
        @test occursin("reply:first", calls[3]["messages"][1]["content"])
        @test !occursin("reply:second", calls[3]["messages"][1]["content"])
        final = calls[4]["messages"]
        system = [message["content"] for message in final if message["role"] == "system"]
        @test length(system) == 2
        @test any(text -> occursin("You are a coding assistant", text), system)
        @test any(text -> occursin("local skill metadata", text), system)
        @test all(text -> !occursin("private body", text), system)
        @test [message["content"] for message in final if message["role"] != "system"] == [JuliaForever.summaryprefix * "checkpoint" * JuliaForever.summarysuffix, "second", "reply:second", "third"]
    end
end
