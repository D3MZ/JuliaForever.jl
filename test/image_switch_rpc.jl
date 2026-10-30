module ImageSwitchRPCTests

using Test, JuliaForever, JSON3, HTTP, Base64

function receive!(channel, predicate)
    while true
        timedwait(() -> isready(channel), 60) == :ok || error("Timed out waiting for image RPC output")
        value = take!(channel)
        predicate(value) && return value
    end
end

function exchange(f, cmd, env)
    mktempdir() do dir
        diagnostic = joinpath(dir, "diagnostic")
        process = open(pipeline(setenv(cmd, env); stderr=diagnostic), "r+")
        channel = Channel{Any}(Inf)
        reader = @async for line in eachline(process)
            put!(channel, JSON3.read(line, Dict{String, Any}))
        end
        try
            send(value) = (println(process, JSON3.write(value)); flush(process))
            command(value) = (send(value); receive!(channel, item -> get(item, "id", "") == value.id))
            prompt(id) = (send((; id, type="prompt", message="read the image")); receive!(channel, item -> get(item, "type", "") == "agent_settled"))
            f(command, prompt)
        finally
            close(process.in)
            timedwait(() -> process_exited(process), 10) == :ok || kill(process)
            wait(process)
            wait(reader)
            success(process) || error("Image RPC failed: $(read(diagnostic, String))")
        end
    end
end

function chatbody(file, first)
    if !first
        chunk = (; id="fixture", object="chat.completion.chunk", model="chat", choices=[(; index=0, delta=(; content="done"), finish_reason="stop")])
        return "data: $(JSON3.write(chunk))\n\ndata: [DONE]\n\n"
    end
    call = Dict("index" => 0, "id" => "image-call", "type" => "function", "function" => Dict("name" => "read", "arguments" => ""))
    args = JSON3.write(Dict("path" => file))
    delta = [Dict("role" => "assistant", "tool_calls" => [call]), Dict("tool_calls" => [Dict("index" => 0, "function" => Dict("arguments" => args))]), Dict()]
    finishes = [nothing, nothing, "tool_calls"]
    chunks = [Dict("id" => "fixture", "object" => "chat.completion.chunk", "model" => "chat", "choices" => [Dict("index" => 0, "delta" => item, "finish_reason" => finish)]) for (item, finish) in zip(delta, finishes)]
    join("data: $(JSON3.write(chunk))\n\n" for chunk in chunks) * "data: [DONE]\n\n"
end

function anthropicbody()
    events = [(; type="message_start", message=(; usage=(; input_tokens=1, output_tokens=0))), (; type="content_block_start", index=0, content_block=(; type="text", text="done")), (; type="content_block_stop", index=0), (; type="message_delta", delta=(; stop_reason="end_turn")), (; type="message_stop")]
    join("event: $(event.type)\ndata: $(JSON3.write(event))\n\n" for event in events)
end

@testset "image results survive RPC provider switches and restart" begin
    requests = Any[]
    filename = Ref("static.gif")
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        push!(requests, (; target=request.target, body=String(request.body)))
        body = occursin("/v1/messages", request.target) ? anthropicbody() : chatbody(filename[], length(requests) == 1)
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], body)
    end
    try
        mktempdir() do root
            project = dirname(@__DIR__)
            base = "http://$(HTTP.server_addr(server))"
            agentdir = joinpath(root, "agent")
            mkpath(agentdir)
            definition(id) = (; id, name=id, input=["text", "image"], reasoning=false, contextWindow=10000, maxTokens=1000)
            first = (; baseUrl=base * "/chat", api="openai-completions", apiKey="synthetic-chat", models=[definition("chat")])
            config = (; providers=(; fixture=first, openai=first, other=(; baseUrl=base * "/anthropic", api="anthropic-messages", apiKey="synthetic-anthropic", models=[definition("claude")])))
            write(joinpath(agentdir, "models.json"), JSON3.write(config))
            env = Dict("PATH" => ENV["PATH"], "HOME" => root, "USERPROFILE" => root, "PI_CODING_AGENT_DIR" => agentdir, "PI_OFFLINE" => "1", "JF_INSTRUCTIONS_DIR" => root, "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "chat", "JULIA_NUM_THREADS" => "4", "JULIA_DEPOT_PATH" => join(DEPOT_PATH, Sys.iswindows() ? ';' : ':'), "TERM" => "dumb")
            for file in ("static.gif", "static.webp")
                filename[] = file
                empty!(requests)
                bytes = read(joinpath(@__DIR__, "fixtures", file))
                imagepath = joinpath(root, file)
                write(imagepath, bytes)
                sessions = joinpath(root, "sessions-" * file)
                cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode rpc --session-dir $sessions --provider fixture --model chat`; dir=root)
                history = exchange(cmd, env) do command, prompt
                    prompt("initial")
                    switched = command((; id="switch", type="set_model", provider="other", modelId="claude"))
                    @test switched["success"]
                    prompt("after-switch")
                    state = command((; id="state", type="get_state"))
                    @test state["data"]["model"]["provider"] == "other"
                    state["data"]["sessionFile"]
                end
                @test length(requests) == 3
                if length(requests) == 3
                    @test all(item -> occursin(base64encode(bytes), item.body), requests[2:3])
                    @test occursin("/v1/messages", requests[3].target)
                end
                rm(imagepath)
                restart = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode rpc --session $history`; dir=root)
                exchange(restart, env) do command, prompt
                    state = command((; id="state", type="get_state"))
                    @test state["data"]["model"]["provider"] == "other"
                    prompt("replay")
                end
                @test length(requests) == 4 && occursin("/v1/messages", requests[4].target) && occursin(base64encode(bytes), requests[4].body)
            end
        end
    finally
        close(server)
        wait(server)
    end
end

end
