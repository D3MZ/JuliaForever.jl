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

end
