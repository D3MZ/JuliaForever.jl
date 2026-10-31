using Test, JuliaForever, HTTP, JSON3

function history_process(base, workspace, args)
    project = dirname(@__DIR__)
    cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project -m JuliaForever $args`; dir=workspace)
    cmd = addenv(cmd, "HOME" => workspace, "USERPROFILE" => workspace, "PI_CODING_AGENT_DIR" => joinpath(workspace, "agent"), "JF_PROVIDER" => "openai", "OPENAI_BASE_URL" => base, "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "synthetic-history-secret", "JF_INSTRUCTIONS_DIR" => workspace)
    success(pipeline(cmd; stdout=devnull, stderr=devnull))
end

if haskey(ENV, "PI_SOURCE")
    @testset "CLI history resume against Pi" begin
        requests = Any[]
        server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
            body = JSON3.read(String(request.body))
            push!(requests, body)
            chunk = (; choices=[(; index=0, delta=(; content="reply:" * body.messages[end].content), finish_reason="stop")])
            HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $(JSON3.write(chunk))\n\ndata: [DONE]\n\n")
        end
        try
            mktempdir() do workspace
                base = "http://$(HTTP.server_addr(server))/v1"
                path = joinpath(workspace, "session.sqlite")
                for prompt in ("one", "two")
                    @test history_process(base, workspace, ["--history", path, prompt])
                end
                source = ENV["PI_SOURCE"]
                @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
                script = joinpath(@__DIR__, "terminal_history_pi.mjs")
                reference = JSON3.read(read(`node $script $source $workspace`, String), Vector{Vector{String}})
                messages = requests[2].messages
                @test [[message.role, message.content] for message in messages if message.role != "system"] == reference
            end
        finally
            close(server)
            wait(server)
        end
    end
end
