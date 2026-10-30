using Test, JuliaForever, JSON3

function session_process(requests, workspace, directory, args; input="", fail=false)
    project = dirname(@__DIR__)
    script = joinpath(@__DIR__, "session_cli_process.jl")
    cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project $script $args`; dir=workspace)
    cmd = addenv(cmd, "JF_SESSION_REQUESTS" => requests, "JF_SESSION_FAIL" => (fail ? "1" : nothing), "JF_SESSION_DIR" => directory, "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "session-test-secret", "JF_INSTRUCTIONS_DIR" => nothing)
    mktempdir() do dir
        stdinpath, output, diagnostics = joinpath.((dir,), ("stdin", "output", "diagnostics"))
        write(stdinpath, input)
        process = run(pipeline(ignorestatus(cmd); stdin=stdinpath, stdout=output, stderr=diagnostics))
        (; status=process.exitcode, output=read(output, String), diagnostics=read(diagnostics, String))
    end
end

@testset "CLI session persistence and selection" begin
        mktempdir() do root
            workspace = joinpath(root, "project")
            other = joinpath(root, "other")
            sessions = joinpath(root, "sessions")
            mkpath.((workspace, other))
            workspace, other = realpath(workspace), realpath(other)
            requestfile = joinpath(root, "requests.jsonl")
            requests() = [JSON3.read(line) for line in eachline(requestfile)]
            run(args; input="", cwd=workspace) = session_process(requestfile, cwd, sessions, args; input)

            @test run(String[]; input="/exit\n").status == 0
            @test !isdir(sessions) || isempty(readdir(sessions))
            @test run(["first"]).output == "reply:first\n"
            files = readdir(sessions; join=true)
            @test length(files) == 1
            firstfile = only(files)
            @test run(["--continue", "second"]).output == "reply:second\n"
            @test [m.content for m in last(requests()) if m.role in ("user", "assistant")] == ["first", "reply:first", "second"]
            @test length(readdir(sessions)) == 1

            @test run(["third"]).output == "reply:third\n"
            files = readdir(sessions; join=true)
            @test length(files) == 2
            secondfile = only(filter(!=(firstfile), files))
            @test run(["--session", firstfile, "fourth"]).output == "reply:fourth\n"
            @test [m.content for m in last(requests()) if m.role in ("user", "assistant")] == ["first", "reply:first", "second", "reply:second", "fourth"]
            @test run(["--continue", "fifth"]).output == "reply:fifth\n"
            @test last(requests())[end-1].content == "reply:fourth"

            selected = run(["--resume", "sixth"]; input="2\n")
            @test selected.status == 0
            @test occursin("first", selected.diagnostics) && occursin("third", selected.diagnostics)
            @test [m.content for m in last(requests()) if m.role in ("user", "assistant")] == ["third", "reply:third", "sixth"]

            fragment = splitext(basename(secondfile))[1][end-7:end]
            @test run(["--session", fragment, "seventh"]).output == "reply:seventh\n"
            @test last(requests())[end-1].content == "reply:sixth"

            before = length(readdir(sessions))
            @test run(["--no-session", "ephemeral"]).output == "reply:ephemeral\n"
            @test length(readdir(sessions)) == before
            @test run(["--continue", "elsewhere"]; cwd=other).output == "reply:elsewhere\n"
            @test [m.content for m in last(requests()) if m.role in ("user", "assistant")] == ["elsewhere"]
            @test length(readdir(sessions)) == before + 1

            alternate = joinpath(root, "alternate")
            @test run(["--session-dir", alternate, "separate"]).output == "reply:separate\n"
            @test length(readdir(alternate)) == 1
            @test run(["--session-dir", alternate, "-c", "again"]).output == "reply:again\n"
            @test [m.content for m in last(requests()) if m.role in ("user", "assistant")] == ["separate", "reply:separate", "again"]

            if haskey(ENV, "PI_SOURCE")
                source = ENV["PI_SOURCE"]
                @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
                reference = JSON3.read(read(`node $(joinpath(@__DIR__, "session_cli_pi.mjs")) $source $workspace $other $(joinpath(root, "pi"))`, String))
                local_sessions = JuliaForever.SessionCatalog.list(sessions, workspace)
                other_sessions = JuliaForever.SessionCatalog.list(sessions, other)
                @test [item.title for item in local_sessions] == reference.titles
                @test first(local_sessions).title == reference.recent
                @test [item.title for item in other_sessions] == reference.other
            end

            unknown = joinpath(root, "missing.sqlite")
            count = length(requests())
            missing = run(["--session", unknown, "not sent"])
            @test missing.status != 0
            @test !isfile(unknown)
            @test length(requests()) == count
            cancelled = run(["--resume"]; input="q\n")
            @test cancelled.status == 0
            @test length(requests()) == count

            crash = joinpath(root, "crash")
            mkpath(crash)
            crash = realpath(crash)
            interrupted = session_process(requestfile, crash, sessions, ["interrupted"]; fail=true)
            @test interrupted.status == 17
            crashfile = only(filter(path -> startswith(basename(path), JuliaForever.SessionCatalog.project(crash) * "--"), readdir(sessions; join=true)))
            count = length(requests())
            blocked = run(["--continue", "not retried"]; cwd=crash)
            @test blocked.status == 1
            @test occursin("uncertain pending effect", blocked.diagnostics)
            @test occursin(crashfile, blocked.diagnostics)
            @test length(requests()) == count
            inspected = run(["--history", crashfile, "--inspect-history"]; cwd=crash)
            @test inspected.status == 0
            @test occursin("Pending model request", inspected.output)
            @test run(["--history", crashfile, "--abandon", "inspected"]; cwd=crash).status == 0
            @test run(["--continue", "after recovery"]; cwd=crash).output == "reply:after recovery\n"
        end
end

@testset "switch sessions with /resume" begin
    mktempdir() do root
        workspace, sessions = joinpath.((root,), ("project", "sessions"))
        mkpath(workspace)
        workspace = realpath(workspace)
        requestfile = joinpath(root, "requests.jsonl")
        requests() = [JSON3.read(line) for line in eachline(requestfile)]
        run(args; input="", fail=false) = session_process(requestfile, workspace, sessions, args; input, fail)

        @test run(["first"]).output == "reply:first\n"
        firstfile = only(readdir(sessions; join=true))
        @test run(["second"]).output == "reply:second\n"
        secondfile = only(filter(!=(firstfile), readdir(sessions; join=true)))

        switched = run(["--session", firstfile]; input="/resume\n1\nswitched\n/exit\n")
        @test switched.status == 0
        @test switched.output == "reply:switched\n"
        @test occursin("first", switched.diagnostics) && occursin("second", switched.diagnostics)
        @test [m.content for m in last(requests()) if m.role in ("user", "assistant")] == ["second", "reply:second", "switched"]
        @test run(["--session", secondfile, "after"]).output == "reply:after\n"
        @test [m.content for m in last(requests()) if m.role in ("user", "assistant")] == ["second", "reply:second", "switched", "reply:switched", "after"]

        cancelled = run(["--session", firstfile]; input="/resume\nq\nkept\n/exit\n")
        @test cancelled.status == 0
        @test cancelled.output == "reply:kept\n"
        @test [m.content for m in last(requests()) if m.role in ("user", "assistant")] == ["first", "reply:first", "kept"]

        @test run(["interrupted"]; fail=true).status == 17
        count = length(requests())
        interrupted = run(["--session", firstfile]; input="/resume\n1\nkept again\n/exit\n")
        @test interrupted.status == 1
        @test occursin("uncertain pending effect", interrupted.diagnostics)
        @test interrupted.output == "reply:kept again\n"
        @test length(requests()) == count + 1
        @test [m.content for m in last(requests()) if m.role in ("user", "assistant")] == ["first", "reply:first", "kept", "reply:kept", "kept again"]

        alternate = joinpath(root, "alternate")
        @test run(["--session-dir", alternate, "alternate"]).output == "reply:alternate\n"
        ephemeral = run(["--no-session", "--session-dir", alternate]; input="/resume\n1\nfollowup\n/exit\n")
        @test ephemeral.status == 0
        @test ephemeral.output == "reply:followup\n"
        @test [m.content for m in last(requests()) if m.role in ("user", "assistant")] == ["alternate", "reply:alternate", "followup"]
    end
end
