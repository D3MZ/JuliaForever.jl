module ImageAgentBoundaryTests

using Test, JuliaForever, HTTP, JSON3, Distributed, Base64
const E = JuliaForever.Execution
const H = JuliaForever.History

function response(anthropic, first, streaming)
    block = first ? Dict("type" => "tool_use", "id" => "call-1", "name" => "read", "input" => Dict("path" => "pixel.png")) : Dict("type" => "text", "text" => "done")
    reason = first ? "tool_use" : "end_turn"
    if anthropic
        if streaming
            events = [Dict("type" => "message_start", "message" => Dict("usage" => Dict("input_tokens" => 1, "output_tokens" => 0))), Dict("type" => "content_block_start", "index" => 0, "content_block" => block), Dict("type" => "content_block_stop", "index" => 0), Dict("type" => "message_delta", "delta" => Dict("stop_reason" => reason), "usage" => Dict("output_tokens" => 1)), Dict("type" => "message_stop")]
            body = join("event: $(event["type"])\ndata: $(JSON3.write(event))\n\n" for event in events)
            return HTTP.Response(200, ["Content-Type" => "text/event-stream"], body)
        end
        data = Dict("content" => [block], "stop_reason" => reason, "usage" => Dict("input_tokens" => 1, "output_tokens" => 1))
    else
        part = first ? Dict("functionCall" => Dict("id" => "call-1", "name" => "read", "args" => Dict("path" => "pixel.png"))) : Dict("text" => "done")
        data = Dict("candidates" => [Dict("content" => Dict("role" => "model", "parts" => [part]), "finishReason" => "STOP")])
        streaming && return HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $(JSON3.write(data))\n\n")
    end
    HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(data))
end

imagebytes(body, ::Anthropic) = body.messages[3].content[1].content[2].source.data
imagebytes(body, ::Google) = body.contents[3].parts[1].functionResponse.parts[1].inlineData.data

@testset "tool image reaches provider and survives replay" begin
    requests = Any[]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        body = JSON3.read(String(request.body))
        push!(requests, body)
        anthropic = occursin("/messages", request.target)
        streaming = anthropic ? get(body, :stream, false) : occursin("streamGenerateContent", request.target)
        response(anthropic, length(requests) == 1, streaming)
    end
    try
        base = "http://$(HTTP.server_addr(server))"
        bytes = read(joinpath(@__DIR__, "fixtures", "pixel.png"))
        for (name, model) in ((:anthropic, Anthropic(base, "claude-fixture", "synthetic")), (:google, Google(base, "gemini-3-fixture", "synthetic")))
            for mode in (:direct, :stream, :executor)
                @testset "$name $mode" begin
                    empty!(requests)
                    mktempdir() do root
                        imagepath = joinpath(root, "pixel.png")
                        write(imagepath, bytes)
                        historypath = joinpath(root, "history.sqlite")
                        history = open(H.SQLite, historypath)
                        context = "image-provider-$name-$mode"
                        pool = mode == :executor ? E.Executor(myid()) : nothing
                        if mode == :executor
                            @test E.install!(context, model, [Read(root)])
                        end
                        try
                            agent = mode == :executor ? Agent(nothing, []; history) : Agent(model, [Read(root)]; history)
                            result = mode == :executor ? respond!(agent, "read the image"; executor=pool, context) : mode == :stream ? respond!(agent, "read the image"; on_event=identity) : respond!(agent, "read the image")
                            value = mode == :executor ? result.value : result
                            @test value == "done"
                            @test length(requests) == 2
                            if value == "done" && length(requests) == 2
                                @test base64decode(imagebytes(requests[2], model)) == bytes
                                close(history)
                                rm(imagepath)
                                history = open(H.SQLite, historypath)
                                restored = mode == :executor ? Agent(nothing, []; history) : Agent(model, [Read(root)]; history)
                                again = mode == :executor ? respond!(restored, "continue"; executor=pool, context) : mode == :stream ? respond!(restored, "continue"; on_event=identity) : respond!(restored, "continue")
                                @test (mode == :executor ? again.value : again) == "done"
                                @test length(requests) == 3
                                @test base64decode(imagebytes(requests[3], model)) == bytes
                                @test !isfile(imagepath)
                            end
                        finally
                            close(history)
                            if mode == :executor
                                close(pool)
                                E.uninstall!(context)
                            end
                        end
                    end
                end
            end
        end
    finally
        close(server)
        wait(server)
    end
end

end
