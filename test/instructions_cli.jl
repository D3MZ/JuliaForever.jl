using Test, JuliaForever, HTTP, JSON3

function instructions_process(base, workspace, piagent; provider="openai", agentdir=nothing, input=nothing, options=String[])
    project = dirname(@__DIR__)
    session = "--history" in options ? String[] : ["--no-session"]
    args = [session; options; isnothing(input) ? ["inspect"] : String[]]
    cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project -m JuliaForever $args`; dir=workspace)
    cmd = addenv(cmd, "HOME" => piagent, "JF_PROVIDER" => provider, "OPENAI_BASE_URL" => base, "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "synthetic-secret", "PI_CODING_AGENT_DIR" => piagent, "JF_INSTRUCTIONS_DIR" => agentdir)
    mktempdir() do dir
        stdinpath, output, diagnostics = joinpath.((dir,), ("stdin", "output", "diagnostics"))
        write(stdinpath, something(input, ""))
        process = run(pipeline(ignorestatus(cmd); stdin=stdinpath, stdout=output, stderr=diagnostics))
        (; status=process.exitcode, output=read(output, String), diagnostics=read(diagnostics, String))
    end
end

function check_tool_guidance(context, definitions)
    listed = [match.captures[1] for match in eachmatch(r"(?m)^- ([^:\n]+): ", context)]
    @test Set(listed) == Set(String(tool.name) for tool in definitions)
    for tool in definitions
        @test occursin("- $(tool.name): $(first(split(tool.description, '\n')))", context)
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

            blank = joinpath(dir, "blank")
            mkpath(blank)
            @test isempty(JuliaForever.Instructions.load(blank))
            tools = ("read", "write", "edit", "bash")
            for provider in ("openai", "openai-responses")
                @test instructions_process(base, blank, piagent; provider) == (; status=0, output="ok\n", diagnostics="")
                request = last(requests)
                messages = provider == "openai" ? request.body.messages : request.body.input
                @test [message.role for message in messages] == ["system", "user"]
                context = messages[1].content
                @test occursin("coding assistant", lowercase(context))
                @test occursin("Working directory: $blank", context)
                @test !occursin("<project_context>", context)
                for name in tools
                    @test occursin("- $name:", context)
                end
                @test all(name -> !occursin("- $name:", context), ("ls", "find", "grep", "powershell"))
                @test !occursin("- greet:", context)
                @test !occursin("- codemode:", context)
                definitions = provider == "openai" ? [tool.function for tool in request.body.tools] : request.body.tools
                check_tool_guidance(context, definitions)
            end

            fixture = joinpath(@__DIR__, "fixtures")
            plugin = ["--plugin-env", fixture, "--plugin", "GreetingPlugin"]
            for options in (plugin, [plugin; "--codemode"])
                @test instructions_process(base, workspace, piagent; options) == (; status=0, output="ok\n", diagnostics="")
                context = last(requests).body.messages[1].content
                @test occursin("Working directory: $workspace", context)
                @test occursin("project fixture", context) && occursin("service override", context)
                @test occursin("- greet: Greet a person", context)
                if "--codemode" in options
                    @test occursin("- codemode:", context)
                    @test occursin("ALL_TOOLS", context)
                else
                    @test !occursin("- codemode:", context)
                end
                @test length(collect(eachmatch(r"(?m)^- greet:", context))) == 1
                check_tool_guidance(context, [tool.function for tool in last(requests).body.tools])
            end

            history = joinpath(dir, "context.sqlite")
            options = [plugin; "--codemode"; "--history"; history]
            @test instructions_process(base, workspace, piagent; options) == (; status=0, output="ok\n", diagnostics="")
            original = last(requests).body.messages[1].content
            write(joinpath(project, "AGENTS.md"), "later project instructions")
            @test instructions_process(base, workspace, piagent; options=["--history", history]) == (; status=0, output="ok\n", diagnostics="")
            resumed = last(requests).body.messages
            @test [message.role for message in resumed] == ["system", "user", "assistant", "user"]
            @test resumed[1].content == original
            @test occursin("project fixture", original) && !occursin("later project instructions", original)
            @test occursin("- greet:", original) && occursin("- codemode:", original)

            for initial in (Dict{String, Any}[], [Dict{String, Any}("role" => "system", "content" => "legacy context")])
                path = joinpath(dir, "legacy-$(length(initial)).sqlite")
                store = open(History.SQLite, path)
                agent = Agent(nothing, Dict{String, JuliaForever.Tool}(), initial; history=store)
                @test agent isa Agent
                close(store)
                @test instructions_process(base, workspace, piagent; options=["--history", path]) == (; status=0, output="ok\n", diagnostics="")
                messages = last(requests).body.messages
                @test length(messages) == length(initial) + 1
                @test [message.content for message in messages] == [getindex.(initial, "content"); "inspect"]
            end
        end
    finally
        close(server)
        wait(server)
    end
end
