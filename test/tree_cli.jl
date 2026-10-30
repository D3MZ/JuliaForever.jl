using Test, JuliaForever, JSON3

function tree_process(requests, workspace, directory, args; input="")
    project = dirname(@__DIR__)
    script = joinpath(@__DIR__, "session_cli_process.jl")
    cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project $script $args`; dir=workspace)
    cmd = addenv(cmd, "JF_SESSION_REQUESTS" => requests, "JF_SESSION_FAIL" => nothing, "JF_SESSION_DIR" => directory, "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "tree-test-secret", "JF_INSTRUCTIONS_DIR" => nothing)
    mktempdir() do dir
        stdinpath, output, diagnostics = joinpath.((dir,), ("stdin", "output", "diagnostics"))
        write(stdinpath, input)
        process = run(pipeline(ignorestatus(cmd); stdin=stdinpath, stdout=output, stderr=diagnostics))
        (; status=process.exitcode, output=read(output, String), diagnostics=read(diagnostics, String))
    end
end

@testset "terminal session tree" begin
    mktempdir() do root
        workspace = joinpath(root, "project")
        mkpath(workspace)
        workspace = realpath(workspace)
        sessions = joinpath(root, "sessions")
        requestfile = joinpath(root, "requests.jsonl")
        requests() = [JSON3.read(line) for line in eachline(requestfile)]
        run(args; input="") = tree_process(requestfile, workspace, sessions, args; input)
        texts() = [m.content for m in last(requests()) if m.role in ("user", "assistant")]

        @test run(["first"]).output == "reply:first\n"
        @test run(["--continue", "second"]).output == "reply:second\n"
        branched = run(["--continue"]; input="/tree\n3\nalternative\n/exit\n")
        @test branched.status == 0
        @test branched.output == "reply:alternative\n"
        @test occursin("first", branched.diagnostics)
        @test occursin("second", branched.diagnostics)
        @test texts() == ["first", "reply:first", "alternative"]
        @test run(["--continue", "after"]).output == "reply:after\n"
        @test texts() == ["first", "reply:first", "alternative", "reply:alternative", "after"]

        original = run(["--continue"]; input="/tree\n4\nlater\n/exit\n")
        @test original.status == 0
        @test original.output == "reply:later\n"
        @test texts() == ["first", "reply:first", "second", "reply:second", "later"]
        @test run(["--continue", "again"]).output == "reply:again\n"
        @test texts() == ["first", "reply:first", "second", "reply:second", "later", "reply:later", "again"]

        count = length(requests())
        @test run(["--continue"]; input="/tree\nq\n/exit\n").status == 0
        @test length(requests()) == count

        ephemeral = run(["--no-session"]; input="one\ntwo\n/tree\n3\nthree\n/exit\n")
        @test ephemeral.status == 0
        @test ephemeral.output == "reply:one\nreply:two\nreply:three\n"
        @test texts() == ["one", "reply:one", "three"]
        @test length(readdir(sessions)) == 1

        legacy = joinpath(sessions, JuliaForever.SessionCatalog.filename(workspace, repeat("a", 32)))
        @test run(["--history", legacy, "legacy"]).output == "reply:legacy\n"
        @test run(["--history", legacy, "second"]).output == "reply:second\n"
        before = read(legacy)
        @test run(["--history", legacy]; input="/tree\nq\n/exit\n").status == 0
        @test read(legacy) == before
        @test run(["--history", legacy]; input="/tree\n3\nchanged\n/exit\n").output == "reply:changed\n"
        @test texts() == ["legacy", "reply:legacy", "changed"]
        inspected = run(["--history", legacy, "--inspect-history"])
        @test inspected.status == 0
        @test occursin("History status: ready", inspected.output)
        @test run(["--history", legacy, "continued"]).output == "reply:continued\n"
        @test texts() == ["legacy", "reply:legacy", "changed", "reply:changed", "continued"]
    end
end
