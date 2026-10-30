using Test, JSON3, JuliaForever

function fork_process(requests, workspace, directory, args; input="", fail=false)
    project = dirname(@__DIR__)
    script = joinpath(@__DIR__, "session_cli_process.jl")
    cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project $script $args`; dir=workspace)
    cmd = addenv(cmd, "JF_SESSION_REQUESTS" => requests, "JF_SESSION_FAIL" => (fail ? "1" : nothing), "JF_SESSION_DIR" => directory, "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "fork-test", "JF_INSTRUCTIONS_DIR" => nothing, "PI_CODING_AGENT_DIR" => joinpath(workspace, "agent"))
    mktempdir() do dir
        stdinpath, output, diagnostics = joinpath.((dir,), ("stdin", "output", "diagnostics"))
        write(stdinpath, input)
        process = run(pipeline(ignorestatus(cmd); stdin=stdinpath, stdout=output, stderr=diagnostics))
        (; status=process.exitcode, output=read(output, String), diagnostics=read(diagnostics, String))
    end
end

@testset "fork and clone sessions" begin
    mktempdir() do root
        workspace = joinpath(root, "project")
        directory = joinpath(root, "sessions")
        mkpath(workspace)
        workspace = realpath(workspace)
        requests = joinpath(root, "requests.jsonl")
        run(args; input="", fail=false) = fork_process(requests, workspace, directory, args; input, fail)
        messages() = [JSON3.read(line) for line in eachline(requests)]
        contents(request) = [message.content for message in request if message.role in ("user", "assistant")]

        source = run(String[]; input="first\nsecond\n/exit\n")
        @test source.status == 0
        @test source.output == "reply:first\nreply:second\n"
        sourcefile = only(readdir(directory; join=true))
        before = read(sourcefile)

        forked = run(["--fork", sourcefile, "third"])
        @test forked.status == 0
        @test forked.output == "reply:third\n"
        @test contents(last(messages())) == ["first", "reply:first", "second", "reply:second", "third"]
        @test read(sourcefile) == before
        @test length(readdir(directory)) == 2

        cloned = run(["--session", sourcefile]; input="/clone\ncloned\n/exit\n")
        @test cloned.status == 0
        @test cloned.output == "reply:cloned\n"
        @test occursin("Cloned", cloned.diagnostics)
        @test contents(last(messages())) == ["first", "reply:first", "second", "reply:second", "cloned"]
        @test read(sourcefile) == before
        @test length(readdir(directory)) == 3

        selected = run(["--session", sourcefile]; input="/fork\n2\nreplacement\n/exit\n")
        @test selected.status == 0
        @test selected.output == "reply:replacement\n"
        @test occursin("Forked", selected.diagnostics)
        @test contents(last(messages())) == ["first", "reply:first", "replacement"]
        beforesecond = contents(last(messages()))[1:end-1]
        @test read(sourcefile) == before
        @test length(readdir(directory)) == 4

        cancelled = run(["--session", sourcefile]; input="/fork\nq\n/exit\n")
        @test cancelled.status == 0
        @test length(readdir(directory)) == 4
        @test read(sourcefile) == before

        ephemeral = joinpath(root, "ephemeral")
        memory = fork_process(requests, workspace, ephemeral, ["--no-session"]; input="one\n/clone\ntwo\n/exit\n")
        @test memory.status == 0
        @test memory.output == "reply:one\nreply:two\n"
        @test contents(last(messages())) == ["one", "reply:one", "two"]
        @test !isdir(ephemeral) || isempty(readdir(ephemeral))

        count = length(messages())
        invalid = run(["--fork", sourcefile, "--no-session", "ignored"])
        @test invalid.status != 0
        @test length(messages()) == count
        @test length(readdir(directory)) == 4

        missing = run(["--fork", joinpath(root, "missing.sqlite"), "ignored"])
        @test missing.status != 0
        @test length(messages()) == count
        @test length(readdir(directory)) == 4

        named = joinpath(root, "named")
        unsaved = fork_process(requests, workspace, named, ["--name", "Unsent"]; input="/clone\n/exit\n")
        @test unsaved.status != 0
        @test occursin("has not been saved", unsaved.diagnostics)
        @test !isdir(named) || isempty(readdir(named))

        crashed = joinpath(root, "crashed")
        result = fork_process(requests, workspace, crashed, ["incomplete"]; fail=true)
        @test result.status == 17
        crashfile = only(readdir(crashed; join=true))
        crashbefore = read(crashfile)
        count = length(messages())
        blocked = run(["--fork", crashfile, "must not run"])
        @test blocked.status != 0
        @test occursin("uncertain pending effect", blocked.diagnostics)
        @test length(messages()) == count
        @test read(crashfile) == crashbefore
        @test length(readdir(directory)) == 4

        branched = run(["--session", sourcefile]; input="/tree\n3\nalternative\n/exit\n")
        @test branched.output == "reply:alternative\n"
        branchbefore = read(sourcefile)
        files = Set(readdir(directory; join=true))
        branchclone = run(["--session", sourcefile]; input="/clone\nclone later\n/exit\n")
        @test branchclone.output == "reply:clone later\n"
        @test contents(last(messages())) == ["first", "reply:first", "alternative", "reply:alternative", "clone later"]
        clonecontext = contents(last(messages()))[1:end-1]
        @test read(sourcefile) == branchbefore
        clonefile = only(setdiff(Set(readdir(directory; join=true)), files))
        files = Set(readdir(directory; join=true))
        full = run(["--fork", sourcefile]; input="/exit\n")
        @test full.status == 0
        fullfile = only(setdiff(Set(readdir(directory; join=true)), files))
        @test read(sourcefile) == branchbefore
        histories = [JuliaForever.History.Tree(open(JuliaForever.History.SQLite, path; create=false)) for path in (sourcefile, fullfile, clonefile)]
        choices(tree) = [entry for entry in JuliaForever.History.entries(tree) if JuliaForever.History.decode_event(only(entry.batch)) isa JuliaForever.Conversation.Input]
        @test length(choices(histories[1])) == 3
        @test length(choices(histories[2])) == 3
        @test length(choices(histories[3])) == 3
        texts(tree) = [JuliaForever.History.decode_event(only(entry.batch)).text for entry in choices(tree)]
        @test texts(histories[1]) == texts(histories[2]) == ["first", "second", "alternative"]
        @test texts(histories[3]) == ["first", "alternative", "clone later"]
        @test length(JuliaForever.History.entries(histories[2])) == length(JuliaForever.History.entries(histories[1]))
        fullcontext = [message["content"] for message in Agent(nothing, []; history=histories[2]).messages if message["role"] in ("user", "assistant")]
        foreach(close, histories)

        other = joinpath(root, "other")
        mkpath(other)
        other = realpath(other)
        files = Set(readdir(directory; join=true))
        foreign = fork_process(requests, other, directory, ["foreign"])
        @test foreign.output == "reply:foreign\n"
        foreignfile = only(setdiff(Set(readdir(directory; join=true)), files))
        foreignbefore = read(foreignfile)
        foreignid = only(JuliaForever.SessionCatalog.list(directory, other)).id
        files = Set(readdir(directory; join=true))
        cross = run(["--fork", foreignid, "local"])
        @test cross.output == "reply:local\n"
        @test contents(last(messages())) == ["foreign", "reply:foreign", "local"]
        @test read(foreignfile) == foreignbefore
        crossfile = only(setdiff(Set(readdir(directory; join=true)), files))
        @test startswith(basename(crossfile), JuliaForever.SessionCatalog.project(workspace) * "--")

        alias1 = joinpath(directory, JuliaForever.SessionCatalog.filename(other, repeat("a", 32)))
        alias2 = joinpath(directory, JuliaForever.SessionCatalog.filename(other, repeat("a", 31) * "b"))
        cp(foreignfile, alias1)
        cp(foreignfile, alias2)
        count = length(messages())
        files = Set(readdir(directory; join=true))
        ambiguous = run(["--fork", repeat("a", 8), "must not run"])
        @test ambiguous.status != 0
        @test length(messages()) == count
        @test Set(readdir(directory; join=true)) == files

        if haskey(ENV, "PI_SOURCE")
            pi = ENV["PI_SOURCE"]
            @test readchomp(`git -C $pi rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
            reference = JSON3.read(read(`node $(joinpath(@__DIR__, "fork_pi.mjs")) $pi`, String))
            @test reference.full == ["first", "reply:first", "alternative", "reply:alternative"]
            @test fullcontext == reference.full
            @test clonecontext == reference.clone
            @test beforesecond == reference.beforeSecond
            @test reference.sourceUnchanged
        end
    end
end
