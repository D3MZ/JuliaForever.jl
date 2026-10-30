using Test, JuliaForever, HTTP, JSON3

function session_estimate_process(base, workspace, sessions, args)
    project = dirname(@__DIR__)
    cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project -m JuliaForever $args`; dir=workspace)
    cmd = addenv(cmd, "JF_SESSION_DIR" => sessions, "JF_INSTRUCTIONS_DIR" => nothing, "JF_PROVIDER" => "openai", "OPENAI_BASE_URL" => base, "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "synthetic-session-key", "PI_SOURCE" => nothing)
    output = joinpath(workspace, "stdout")
    diagnostics = joinpath(workspace, "stderr")
    process = run(pipeline(ignorestatus(cmd); stdin=devnull, stdout=output, stderr=diagnostics))
    (; status=process.exitcode, output=read(output, String), diagnostics=read(diagnostics, String))
end

@testset "streamed reasoning in resumed CLI sessions and context estimates" begin
    for field in ("reasoning_content", "reasoning", "reasoning_text")
        @testset "$field" begin
            requests = Channel{Any}(2)
            later = field == "reasoning_content" ? "reasoning" : "reasoning_content"
            thinking = "π😀 reasoning from the first turn"
            server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
                body = JSON3.read(String(request.body))
                put!(requests, body)
                chunks = if body.messages[end].content == "first"
                    [Dict("choices" => [Dict("delta" => Dict(field => "π😀"), "finish_reason" => nothing)]), Dict("choices" => [Dict("delta" => Dict(later => " reasoning from the first turn", "content" => "answer"), "finish_reason" => "stop")])]
                else
                    [(; choices=[(; delta=(; content="continued"), finish_reason="stop")])]
                end
                stream = join("data: $(JSON3.write(chunk))\n\n" for chunk in chunks) * "data: [DONE]\n\n"
                HTTP.Response(200, ["Content-Type" => "text/event-stream"], stream)
            end
            try
                mktempdir(Sys.isapple() ? "/private/tmp" : tempdir()) do root
                    workspace = joinpath(root, "workspace")
                    sessions = joinpath(root, "sessions")
                    mkpath(workspace)
                    base = "http://$(HTTP.server_addr(server))/v1"
                    first = session_estimate_process(base, workspace, sessions, ["first"])
                    @test first == (; status=0, output="answer\n", diagnostics="")
                    first_request = isready(requests) ? take!(requests) : nothing
                    @test !isnothing(first_request) && first_request.stream == true
                    path = only(readdir(sessions; join=true))
                    @test endswith(path, ".sqlite")

                    second = session_estimate_process(base, workspace, sessions, ["--continue", "second"])
                    @test second == (; status=0, output="continued\n", diagnostics="")
                    replayed = isready(requests) ? take!(requests) : nothing
                    @test !isnothing(replayed)
                    @test length(readdir(sessions)) == 1
                    @test [message.role for message in replayed.messages] == ["system", "user", "assistant", "user"]
                    assistant_request = replayed.messages[3]
                    @test get(assistant_request, Symbol(field), nothing) == thinking
                    @test [key for key in ("reasoning_content", "reasoning", "reasoning_text") if haskey(assistant_request, Symbol(key))] == [field]

                    history = JuliaForever.History.Tree(open(JuliaForever.History.SQLite, path; create=false))
                    try
                        restored = Agent(nothing, []; history)
                        messages = restored.state.messages
                        assistant = messages[3]
                        @test JuliaForever.ContextEstimates.tokens(assistant) == JuliaForever.ContextEstimates.tokens("answer" * thinking)
                        metadata = copy(assistant.metadata)
                        delete!(metadata, field)
                        stripped = copy(messages)
                        stripped[3] = JuliaForever.Conversation.Assistant(assistant.content, assistant.calls, assistant.finish, assistant.done; metadata)
                        estimated = JuliaForever.ContextEstimates.estimate(messages)
                        without_reasoning = JuliaForever.ContextEstimates.estimate(stripped)
                        @test estimated.total > without_reasoning.total
                        @test estimated.total - without_reasoning.total == JuliaForever.ContextEstimates.tokens(assistant) - JuliaForever.ContextEstimates.tokens(stripped[3])
                        @test estimated.reported == 0 && estimated.index === nothing
                    finally
                        close(history)
                    end
                end
            finally
                close(server)
                wait(server)
                close(requests)
            end
        end
    end
end
