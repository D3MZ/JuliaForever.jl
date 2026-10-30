module FileCliLoopbackTests
using Test, JuliaForever, HTTP, JSON3, Base64

@testset "CLI image attachment and resume through streaming HTTP" begin
    requests = Any[]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        push!(requests, JSON3.read(String(request.body)))
        chunk = Dict("choices" => [Dict("index" => 0, "delta" => Dict("content" => "done"), "finish_reason" => "stop")])
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: " * JSON3.write(chunk) * "\n\ndata: [DONE]\n\n")
    end
    try
        mktempdir() do workspace
            workspace = realpath(workspace)
            image = read(joinpath(@__DIR__, "fixtures", "pixel.png"))
            write(joinpath(workspace, "image.png"), image)
            project = dirname(@__DIR__)
            base = "http://$(HTTP.server_addr(server))"
            function cli(args)
                cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever $args`; dir=workspace)
                cmd = addenv(cmd, "JF_PROVIDER" => "openai", "OPENAI_BASE_URL" => base, "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "synthetic", "JF_SESSION_DIR" => joinpath(workspace, "sessions"), "JF_INSTRUCTIONS_DIR" => workspace, "PI_CODING_AGENT_DIR" => joinpath(workspace, "agent"))
                mktempdir() do temp
                    stdinfile, outfile, errfile = joinpath.((temp,), ("stdin", "out", "err"))
                    write(stdinfile, "")
                    process = run(pipeline(ignorestatus(cmd); stdin=stdinfile, stdout=outfile, stderr=errfile))
                    (; status=process.exitcode, output=read(outfile, String), diagnostics=read(errfile, String))
                end
            end
            first = cli(["@image.png", "describe"])
            @test first.status == 0 && first.output == "done\n"
            @test length(requests) == 1
            content = last(requests[1].messages).content
            @test occursin("<file name=", content[1].text) && endswith(content[1].text, "describe")
            @test content[2].image_url.url == "data:image/png;base64," * base64encode(image)
            write(joinpath(workspace, "image.png"), "changed")
            second = cli(["--continue", "next"])
            @test second.status == 0 && second.output == "done\n"
            @test length(requests) == 2
            original = only(message for message in requests[2].messages if message.role == "user" && message.content isa JSON3.Array)
            @test original.content[2].image_url.url == "data:image/png;base64," * base64encode(image)
            @test last(requests[2].messages).content == "next"
        end
    finally
        close(server)
        wait(server)
    end
end
end
