module ParallelCliTests

using Test, JuliaForever, HTTP, JSON3
const H = JuliaForever.History
const C = JuliaForever.Conversation

@testset "saved terminal runs tool calls concurrently" begin
    if Sys.isunix()
        requests = Any[]
        server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
            push!(requests, JSON3.read(String(request.body)))
            if length(requests) == 1
                commands = ["printf started > started; read -r token < gate; printf 'first:%s' \"\$token\"", "printf 'ready\\n' > gate; printf second"]
                calls = [Dict("index" => index - 1, "id" => string(index), "type" => "function", "function" => Dict("name" => "bash", "arguments" => JSON3.write((; command, timeout=10)))) for (index, command) in enumerate(commands)]
                chunk = (; choices=[(; index=0, delta=(; tool_calls=calls), finish_reason="tool_calls")])
            else
                chunk = (; choices=[(; index=0, delta=(; content="done"), finish_reason="stop")])
            end
            HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $(JSON3.write(chunk))\n\ndata: [DONE]\n\n")
        end
        try
            mktempdir() do root
                run(`mkfifo $(joinpath(root, "gate"))`)
                path = joinpath(root, "history.sqlite")
                output = joinpath(root, "stdout")
                diagnostics = joinpath(root, "stderr")
                project = dirname(@__DIR__)
                base = "http://$(HTTP.server_addr(server))/v1"
                cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project -m JuliaForever --history $path 'run both'`; dir=root)
                cmd = addenv(cmd, "HOME" => root, "JULIA_DEPOT_PATH" => join(DEPOT_PATH, ':'), "PI_CODING_AGENT_DIR" => joinpath(root, "empty-pi"), "JF_PROVIDER" => "openai", "OPENAI_BASE_URL" => base, "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "synthetic", "JF_INSTRUCTIONS_DIR" => nothing)
                process = run(pipeline(ignorestatus(cmd); stdout=output, stderr=diagnostics))
                @test success(process)
                @test read(output, String) == "done\n"
                @test isfile(joinpath(root, "started"))
                @test length(requests) == 2
                if length(requests) == 2
                    tools = [message for message in requests[2].messages if message.role == "tool"]
                    @test [message.tool_call_id for message in tools] == ["1", "2"]
                    @test length(tools) == 2 && occursin("first:ready", tools[1].content) && occursin("second", tools[2].content)
                end
                history = open(H.SQLite, path)
                try
                    restored = Agent(nothing, []; history)
                    @test [message.id for message in restored.state.messages if message isa C.ToolMessage] == ["1", "2"]
                finally
                    close(history)
                end
            end
        finally
            close(server)
            wait(server)
        end
    end
end

end
