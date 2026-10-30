using Test, JuliaForever, JSON3
function refresh_process(requests, workspace, directory, args; input="", fail=false)
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

@testset "new session refreshes skills; resume preserves recorded context" begin
    mktempdir() do root
        workspace, sessions = joinpath.((root,), ("project", "sessions"))
        mkpath(joinpath(workspace, ".pi", "skills", "example"))
        workspace = realpath(workspace)
        skill = joinpath(workspace, ".pi", "skills", "example", "SKILL.md")
        requests = joinpath(root, "requests")
        write(skill, "---\nname: example\ndescription: original metadata\n---\nprivate body\n")
        first = refresh_process(requests, workspace, sessions, ["first"])
        @test first.status == 0
        original = only(readdir(sessions; join=true))
        write(skill, "---\nname: example\ndescription: updated metadata\n---\nprivate body\n")
        resumed = refresh_process(requests, workspace, sessions, ["--session", original]; input="second\n/new\nthird\n/exit\n")
        @test resumed.status == 0
        captured = JSON3.read.(readlines(requests))
        systems(request) = [m.content for m in request if m.role == "system"]
        @test any(s -> occursin("original metadata", s), systems(captured[2]))
        @test all(!occursin("updated metadata", s) for s in systems(captured[2]))
        @test any(s -> occursin("updated metadata", s), systems(captured[3]))
        @test all(!occursin("private body", s) for s in systems(captured[3]))
        @test [m.content for m in captured[3] if m.role == "user"] == ["third"]
        @test length(readdir(sessions)) == 2
        ephemeral = refresh_process(requests, workspace, sessions, ["--no-session"]; input="/new\nfourth\n/exit\n")
        @test ephemeral.status == 0
        @test length(readdir(sessions)) == 2
    end
end
