using Test, JSON3, JuliaForever

function named_session_process(requests, workspace, directory, args; input="")
    project = dirname(@__DIR__)
    script = joinpath(@__DIR__, "session_cli_process.jl")
    cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project $script $args`; dir=workspace)
    cmd = addenv(cmd, "JF_SESSION_REQUESTS" => requests, "JF_SESSION_DIR" => directory, "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "session-test-secret", "JF_INSTRUCTIONS_DIR" => nothing, "PI_CODING_AGENT_DIR" => joinpath(workspace, "empty-agent"))
    mktempdir() do dir
        stdinpath, output, diagnostics = joinpath.((dir,), ("stdin", "output", "diagnostics"))
        write(stdinpath, input)
        process = run(pipeline(ignorestatus(cmd); stdin=stdinpath, stdout=output, stderr=diagnostics))
        (; status=process.exitcode, output=read(output, String), diagnostics=read(diagnostics, String))
    end
end

@testset "new and named sessions" begin
    mktempdir() do root
        workspace = joinpath(root, "project")
        directory = joinpath(root, "sessions")
        mkpath(workspace)
        workspace = realpath(workspace)
        requestfile = joinpath(root, "requests.jsonl")
        requests() = [JSON3.read(line) for line in eachline(requestfile)]
        run(args; input="", sessions=directory) = named_session_process(requestfile, workspace, sessions, args; input)

        unnamed = run(String[]; input="/name\n/exit\n")
        @test unnamed.status == 0
        @test occursin("Usage: /name <name>", unnamed.diagnostics)
        @test !isdir(directory) || isempty(readdir(directory))

        before = run(["--name", " Before\nFirst "]; input="/name\n/exit\n")
        @test before.status == 0
        @test occursin("Session name: Before First", before.diagnostics)
        @test !isdir(directory) || isempty(readdir(directory))

        session = run(String[]; input="/name First Name\none\n/name First Renamed\n/new\n/name Second\ntwo\n/resume\n2\nagain\n/exit\n")
        @test session.status == 0
        @test session.output == "reply:one\nreply:two\nreply:again\n"
        @test occursin("First Renamed", session.diagnostics)
        @test occursin("Second", session.diagnostics)
        @test length(readdir(directory)) == 2
        users = [[message.content for message in request if message.role == "user"] for request in requests()]
        @test users == [["one"], ["two"], ["one", "again"]]
        titles = [item.title for item in JuliaForever.SessionCatalog.list(directory, workspace)]
        @test Set(titles) == Set(["First Renamed", "Second"])
        if haskey(ENV, "PI_SOURCE")
            source = ENV["PI_SOURCE"]
            @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
            reference = JSON3.read(read(`node $(joinpath(@__DIR__, "session_names_pi.mjs")) $source`, String))
            @test reference.beforePrompt == false
            @test reference.normalized == "First Name"
            @test Set(reference.titles) == Set(titles)
        end

        ephemeral = joinpath(root, "ephemeral")
        result = run(["--no-session"]; sessions=ephemeral, input="one\n/new\ntwo\n/exit\n")
        @test result.status == 0
        @test result.output == "reply:one\nreply:two\n"
        @test !isdir(ephemeral) || isempty(readdir(ephemeral))
        @test [[message.content for message in request if message.role == "user"] for request in requests()[end-1:end]] == [["one"], ["two"]]

        named = run(["--name", " CLI title ", "flag prompt"])
        @test named.status == 0
        @test named.output == "reply:flag prompt\n"
        @test first(JuliaForever.SessionCatalog.list(directory, workspace)).title == "CLI title"
        count = length(requests())
        @test run(["--name", ""]).status != 0
        @test length(requests()) == count
    end
end
