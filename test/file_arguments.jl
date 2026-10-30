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

@testset "file argument errors and piped input" begin
    mktempdir() do workspace
        workspace = realpath(workspace)
        result = fileargs_process(workspace, ["--no-session", "@missing.txt", "unused"])
        @test result.status == 1
        @test isempty(result.requests)
        @test occursin("missing.txt", result.diagnostics)
        @test !isdir(joinpath(workspace, "sessions"))
    end
    mktempdir() do workspace
        workspace = realpath(workspace)
        write(joinpath(workspace, "notes.txt"), "note")
        result = fileargs_process(workspace, ["--no-session", "--", "@notes.txt", "first", "--help"]; input=" pipe \n")
        @test result.status == 0
        @test length(result.requests) == 2
        firstrequest, secondrequest = result.requests
        @test last(firstrequest).content == "pipe<file name=\"$(joinpath(workspace, "notes.txt"))\">\nnote\n</file>\nfirst"
        @test last(secondrequest).content == "--help"
        @test length([message for message in secondrequest if message.role == "user"]) == 2
    end
end

@testset "file images survive CLI resume" begin
    mktempdir() do workspace
        workspace = realpath(workspace)
        cp(joinpath(@__DIR__, "fixtures", "pixel.jpg"), joinpath(workspace, "photo.jpg"))
        first = fileargs_process(workspace, ["@photo.jpg", "what is this?"])
        @test first.status == 0 && length(first.requests) == 1
        resumed = fileargs_process(workspace, ["--continue", "next"])
        @test resumed.status == 0 && length(resumed.requests) == 2
        prior = only(message for message in last(resumed.requests) if message.role == "user" && haskey(message, :images))
        @test prior.images[1].mime == "image/jpeg"
        @test base64decode(prior.images[1].data) == read(joinpath(workspace, "photo.jpg"))
        @test last(last(resumed.requests)).content == "next"
    end
end

@testset "empty file and first message preserve later prompts" begin
    mktempdir() do workspace
        write(joinpath(workspace, "empty.txt"), "")
        result = fileargs_process(workspace, ["--no-session", "@empty.txt", "", "second"])
        @test result.status == 0
        @test length(result.requests) == 1
        @test last(first(result.requests)).content == "second"
    end
end

@testset "file arguments can precede options" begin
    mktempdir() do workspace
        workspace = realpath(workspace)
        write(joinpath(workspace, "notes.txt"), "note")
        result = fileargs_process(workspace, ["@notes.txt", "--no-session", "describe"])
        @test result.status == 0
        @test length(result.requests) == 1
        @test last(first(result.requests)).content == "<file name=\"$(joinpath(workspace, "notes.txt"))\">\nnote\n</file>\ndescribe"
        @test !isdir(joinpath(workspace, "sessions"))
    end
end
