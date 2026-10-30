using Test, JuliaForever, JSON3

function tree_process(requests, workspace, directory, args; input="", events=nothing)
    project = dirname(@__DIR__)
    script = joinpath(@__DIR__, "session_cli_process.jl")
    cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project $script $args`; dir=workspace)
    cmd = addenv(cmd, "JF_SESSION_REQUESTS" => requests, "JF_SESSION_FAIL" => nothing, "JF_SESSION_DIR" => directory, "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "tree-test-secret", "JF_INSTRUCTIONS_DIR" => nothing, "JF_TEST_EVENTS" => events)
    mktempdir() do dir
        stdinpath, output, diagnostics = joinpath.((dir,), ("stdin", "output", "diagnostics"))
        write(stdinpath, input)
        process = run(pipeline(ignorestatus(cmd); stdin=stdinpath, stdout=output, stderr=diagnostics))
        (; status=process.exitcode, output=read(output, String), diagnostics=read(diagnostics, String))
    end
end

@testset "tree selection redacts diagnostics without changing messages" begin
    mktempdir() do root
        workspace = joinpath(root, "project")
        sessions = joinpath(root, "sessions")
        requests = joinpath(root, "requests.jsonl")
        mkpath(workspace)
        text = "before tree-test-secret after"
        @test tree_process(requests, workspace, sessions, [text]).status == 0
        selected = tree_process(requests, workspace, sessions, ["--continue"]; input="/tree\n1\n\n/exit\n")
        @test selected.status == 0
        @test occursin("before [redacted] after", selected.diagnostics)
        @test occursin("Message [before [redacted] after]", selected.diagnostics)
        @test !occursin("tree-test-secret", selected.diagnostics)
        @test selected.output == "reply:" * text * "\n"
        messages = JSON3.read(last(readlines(requests)))
        @test [m.content for m in messages if m.role == "user"] == [text]
    end
end

@testset "tree branch retains plugin observers" begin
    mktempdir() do root
        workspace = joinpath(root, "project")
        sessions = joinpath(root, "sessions")
        requests = joinpath(root, "requests.jsonl")
        events = joinpath(root, "events.txt")
        mkpath(workspace)
        fixture = joinpath(@__DIR__, "fixtures")
        result = tree_process(requests, workspace, sessions, ["--plugin-env", fixture, "--plugin", "GreetingPlugin", "--no-session"]; input="first\n/tree\n1\nchanged\n/exit\n", events)
        @test result.status == 0
        @test result.output == "reply:first\nreply:changed\n"
        @test readlines(events) == ["agent_start", "agent_end", "agent_start", "agent_end"]
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
        @test only(JuliaForever.SessionCatalog.list(sessions, workspace)).title == "first"
        @test run(["--continue"]; input="/name First\nsecond\n/exit\n").output == "reply:second\n"
        branched = run(["--continue"]; input="/tree\n3\nalternative\n/name Second\n/exit\n")
        @test branched.status == 0
        @test branched.output == "reply:alternative\n"
        @test occursin("first", branched.diagnostics)
        @test occursin("second", branched.diagnostics)
        @test texts() == ["first", "reply:first", "alternative"]
        @test only(JuliaForever.SessionCatalog.list(sessions, workspace)).title == "Second"
        @test run(["--continue", "after"]).output == "reply:after\n"
        @test texts() == ["first", "reply:first", "alternative", "reply:alternative", "after"]

        original = run(["--continue"]; input="/tree\n4\n/name\nlater\n/exit\n")
        @test original.status == 0
        @test original.output == "reply:later\n"
        @test occursin("Session name: Second", original.diagnostics)
        @test only(JuliaForever.SessionCatalog.list(sessions, workspace)).title == "Second"
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

        history = joinpath(sessions, JuliaForever.SessionCatalog.filename(workspace, repeat("a", 32)))
        @test run(["--history", history, "history"]).output == "reply:history\n"
        @test run(["--history", history, "second"]).output == "reply:second\n"
        before = read(history)
        @test run(["--history", history]; input="/tree\nq\n/exit\n").status == 0
        @test read(history) == before
        @test run(["--history", history]; input="/tree\n3\nchanged\n/exit\n").output == "reply:changed\n"
        @test texts() == ["history", "reply:history", "changed"]
        inspected = run(["--history", history, "--inspect-history"])
        @test inspected.status == 0
        @test occursin("History status: ready", inspected.output)
        @test run(["--history", history, "continued"]).output == "reply:continued\n"
        @test texts() == ["history", "reply:history", "changed", "reply:changed", "continued"]
    end
end
