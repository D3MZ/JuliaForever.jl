using Test, JuliaForever, JSON3

function session_process(requests, workspace, directory, args; input="", fail=false, key="session-test-secret")
    project = dirname(@__DIR__)
    script = joinpath(@__DIR__, "session_cli_process.jl")
    cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project $script $args`; dir=workspace)
    cmd = addenv(cmd, "JF_SESSION_REQUESTS" => requests, "JF_SESSION_FAIL" => (fail ? "1" : nothing), "JF_SESSION_DIR" => directory, "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => key, "JF_INSTRUCTIONS_DIR" => nothing)
    mktempdir() do dir
        stdinpath, output, diagnostics = joinpath.((dir,), ("stdin", "output", "diagnostics"))
        write(stdinpath, input)
        process = run(pipeline(ignorestatus(cmd); stdin=stdinpath, stdout=output, stderr=diagnostics))
        (; status=process.exitcode, output=read(output, String), diagnostics=read(diagnostics, String))
    end
end

@testset "session diagnostics redact provider credentials" begin
    for key in ("session-test-secret", join(("synthetic", "\"", "\\", "\$", "secret")))
        mktempdir() do root
            workspace = joinpath(root, "project")
            sessions = joinpath(root, "sessions-" * key)
            requests = joinpath(root, "requests.jsonl")
            mkpath(workspace)
            escaped = chop(repr(key); head=1, tail=1)
            crashed = session_process(requests, workspace, sessions, ["interrupted"]; fail=true, key)
            @test crashed.status == 17
            blocked = session_process(requests, workspace, sessions, ["--continue", "not retried"]; key)
            @test blocked.status == 1 && occursin("History file:", blocked.diagnostics)
            @test occursin("[redacted]", blocked.diagnostics)
            @test !occursin(key, blocked.diagnostics) && !occursin(escaped, blocked.diagnostics)
            invalid = session_process(requests, workspace, sessions, ["--session", joinpath(root, "missing-" * key), "not sent"]; key)
            @test invalid.status == 2
            @test occursin("[redacted]", invalid.diagnostics)
            @test !occursin(key, invalid.diagnostics) && !occursin(escaped, invalid.diagnostics)
        end
    end
end

@testset "session picker redacts provider credentials" begin
    mktempdir() do root
        workspace = joinpath(root, "project")
        sessions = joinpath(root, "sessions")
        requests = joinpath(root, "requests.jsonl")
        key = "SYNTHETIC_API_ABC"
        mkpath(workspace)
        created = session_process(requests, workspace, sessions, ["before " * key * " after"]; key)
        @test created.status == 0
        longtitle = repeat("z", 96) * key * " tail"
        @test session_process(requests, workspace, sessions, [longtitle]; key).status == 0
        picked = session_process(requests, workspace, sessions, ["--resume"]; input="q\n", key)
        @test picked.status == 0
        @test occursin("before [redacted] after", picked.diagnostics)
        @test occursin(repeat("z", 96), picked.diagnostics)
        @test !occursin(key, picked.diagnostics)
        @test !occursin(first(key, 4), picked.diagnostics)
    end
end

@testset "sessions preserve plugin context" begin
    mktempdir() do root
        workspace = joinpath(root, "project")
        sessions = joinpath(root, "sessions")
        mkpath(workspace)
        workspace = realpath(workspace)
        write(joinpath(workspace, "AGENTS.md"), "session fixture instructions")
        requests = joinpath(root, "requests.jsonl")
        fixture = joinpath(@__DIR__, "fixtures")
        started = session_process(requests, workspace, sessions, ["--plugin-env", fixture, "--plugin", "GreetingPlugin", "--codemode", "first"])
        @test started.status == 0 && started.output == "reply:first\n"
        messages = JSON3.read(first(readlines(requests)))
        context = first(messages).content
        @test occursin("session fixture instructions", context)
        @test occursin("- greet:", context) && occursin("- codemode:", context)
        write(joinpath(workspace, "AGENTS.md"), "changed instructions")
        resumed = session_process(requests, workspace, sessions, ["--continue", "second"])
        @test resumed.status == 0 && resumed.output == "reply:second\n"
        messages = JSON3.read(last(readlines(requests)))
        @test first(messages).content == context
        @test [m.content for m in messages if m.role in ("user", "assistant")] == ["first", "reply:first", "second"]
        missing = joinpath(root, "not-opened.sqlite")
        invalid = session_process(requests, workspace, sessions, ["--history", missing, "--continue", "--inspect-history"])
        @test invalid.status == 2 && !isfile(missing)
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
