using Test, JuliaForever, HTTP, JSON3

function instructions_process(base, workspace, piagent; provider="openai", agentdir=nothing, input=nothing)
    project = dirname(@__DIR__)
    args = isnothing(input) ? ["--no-session", "inspect"] : ["--no-session"]
    cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project -m JuliaForever $args`; dir=workspace)
    cmd = addenv(cmd, "JF_PROVIDER" => provider, "OPENAI_BASE_URL" => base, "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "synthetic-secret", "PI_CODING_AGENT_DIR" => piagent, "JF_INSTRUCTIONS_DIR" => agentdir)
    mktempdir() do dir
        stdinpath, output, diagnostics = joinpath.((dir,), ("stdin", "output", "diagnostics"))
        write(stdinpath, something(input, ""))
        process = run(pipeline(ignorestatus(cmd); stdin=stdinpath, stdout=output, stderr=diagnostics))
        (; status=process.exitcode, output=read(output, String), diagnostics=read(diagnostics, String))
    end
end

@testset "CLI project instructions" begin
    requests = []
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        body = JSON3.read(String(request.body))
        push!(requests, (; target=request.target, body))
        if request.target == "/v1/responses"
            delta = JSON3.write((; type="response.output_text.delta", delta="ok"))
            output = [(; type="message", content=[(; type="output_text", text="ok")])]
            done = JSON3.write((; type="response.completed", response=(; status="completed", output)))
            return HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $delta\n\ndata: $done\n\n")
        end
        data = JSON3.write((; choices=[(; delta=(; content="ok"), finish_reason="stop")]))
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $data\n\ndata: [DONE]\n\n")
    end
    try
        mktempdir() do path
            dir = realpath(path)
            globaldir = joinpath(dir, "global")
            piagent = joinpath(dir, "pi")
            project = joinpath(dir, "project")
            workspace = joinpath(project, "service")
            mkpath.((globaldir, piagent, workspace))
            write(joinpath(globaldir, "AGENTS.md"), "global fixture")
            write(joinpath(piagent, "AGENTS.md"), "unused Pi fixture")
            write(joinpath(project, "AGENTS.md"), "project fixture")
            write(joinpath(workspace, "AGENTS.override.md"), "service override")
            write(joinpath(workspace, "AGENTS.md"), "ignored service")
            base = "http://$(HTTP.server_addr(server))/v1"
            for (provider, agentdir) in (("openai", nothing), ("openai-responses", globaldir))
                @test instructions_process(base, workspace, piagent; provider, agentdir) == (; status=0, output="ok\n", diagnostics="")
                request = last(requests)
                messages = provider == "openai" ? request.body.messages : request.body.input
                @test request.target == (provider == "openai" ? "/v1/chat/completions" : "/v1/responses")
                @test messages[1].role == "system"
                @test messages[end].role == "user" && messages[end].content == "inspect"
                text = messages[1].content
                project_section = "<project_instructions path=\"$(joinpath(project, "AGENTS.md"))\">\nproject fixture\n</project_instructions>"
                service_section = "<project_instructions path=\"$(joinpath(workspace, "AGENTS.override.md"))\">\nservice override\n</project_instructions>"
                @test occursin(project_section, text) && occursin(service_section, text)
                @test first(findfirst(project_section, text)) < first(findfirst(service_section, text))
                @test !occursin("ignored service", text) && !occursin("unused Pi fixture", text)
                if isnothing(agentdir)
                    @test !occursin("global fixture", text)
                else
                    global_section = "<project_instructions path=\"$(joinpath(globaldir, "AGENTS.md"))\">\nglobal fixture\n</project_instructions>"
                    @test occursin(global_section, text) && first(findfirst(global_section, text)) < first(findfirst(project_section, text))
                end
            end
            @test instructions_process(base, workspace, piagent; input="first\nsecond\n/exit\n") == (; status=0, output="ok\nok\n", diagnostics="")
            firstturn, secondturn = requests[end-1].body.messages, requests[end].body.messages
            @test [message.role for message in firstturn] == ["system", "user"]
            @test [message.role for message in secondturn] == ["system", "user", "assistant", "user"]
            @test firstturn[1].content == secondturn[1].content
            @test secondturn[end].content == "second"
        end
    finally
        close(server)
        wait(server)
    end
end
