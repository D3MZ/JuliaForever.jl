using Test, JuliaForever, JSON3, Base64

function fileargs_process(workspace, args; input="", sessiondir=joinpath(workspace, "sessions"))
    project = dirname(@__DIR__)
    requests = joinpath(workspace, "requests.jsonl")
    script = joinpath(@__DIR__, "session_cli_process.jl")
    cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project $script $args`; dir=workspace)
    cmd = addenv(cmd, "JF_SESSION_REQUESTS" => requests, "JF_SESSION_FAIL" => nothing, "JF_SESSION_DIR" => sessiondir, "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "synthetic", "JF_INSTRUCTIONS_DIR" => nothing, "PI_CODING_AGENT_DIR" => joinpath(workspace, "agent"))
    mktempdir() do dir
        stdinpath, output, diagnostics = joinpath.((dir,), ("stdin", "output", "diagnostics"))
        write(stdinpath, input)
        process = run(pipeline(ignorestatus(cmd); stdin=stdinpath, stdout=output, stderr=diagnostics))
        recorded = isfile(requests) ? [JSON3.read(line) for line in eachline(requests)] : []
        (; status=process.exitcode, output=read(output, String), diagnostics=read(diagnostics, String), requests=recorded)
    end
end

@testset "Pi file arguments" begin
    mktempdir() do workspace
        workspace = realpath(workspace)
        write(joinpath(workspace, "notes.txt"), "\ufeffalpha\nβ")
        write(joinpath(workspace, "empty.txt"), "")
        cp(joinpath(@__DIR__, "fixtures", "pixel.png"), joinpath(workspace, "picture.dat"))
        args = ["@notes.txt", "summarize", "@empty.txt", "@picture.dat"]
        reference = nothing
        if haskey(ENV, "PI_SOURCE")
            pi = ENV["PI_SOURCE"]
            @test readchomp(`git -C $pi rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
            cmd = Cmd(`node $(joinpath(@__DIR__, "file_arguments_pi.mjs")) $pi $(JSON3.write(args))`; dir=workspace)
            reference = JSON3.read(read(cmd, String))
        end
        actual = fileargs_process(workspace, ["--no-session"; args])
        @test actual.status == 0
        @test length(actual.requests) == 1
        message = last(first(actual.requests))
        @test message.role == "user"
        expected = "<file name=\"$(joinpath(workspace, "notes.txt"))\">\nalpha\nβ\n</file>\n<file name=\"$(joinpath(workspace, "picture.dat"))\"></file>\nsummarize"
        @test message.content == expected
        @test message.images[1].mime == "image/png"
        @test base64decode(message.images[1].data) == read(joinpath(workspace, "picture.dat"))
        if reference !== nothing
            @test message.content == reference.initial.initialMessage
            @test message.images[1].mime == reference.initial.initialImages[1].mimeType
            @test message.images[1].data == reference.initial.initialImages[1].data
        end
    end
end
