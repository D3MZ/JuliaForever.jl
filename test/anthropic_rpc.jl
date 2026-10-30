using Test, JuliaForever, HTTP, JSON3

@testset "Anthropic RPC thinking reaches the wire" begin
    requests = Channel{Any}(30)
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        put!(requests, JSON3.read(String(request.body), Dict{String, Any}))
        events = [(; type="message_start", message=(; usage=(; input_tokens=20, output_tokens=1))), (; type="content_block_start", index=0, content_block=(; type="text", text="answer")), (; type="content_block_stop", index=0), (; type="message_delta", delta=(; stop_reason="end_turn")), (; type="message_stop")]
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], join("data: $(JSON3.write(event))\n\n" for event in events))
    end
    try
        mktempdir() do workspace
            project = dirname(@__DIR__)
            base = "http://$(HTTP.server_addr(server))"
            model = "claude-sonnet-4-5"
            function runrpc(args; key="synthetic-secret", configured=false)
                agentdir = mktempdir(workspace)
                if configured
                    write(joinpath(agentdir, "models.json"), JSON3.write((; providers=(; anthropic=(; modelOverrides=Dict(model => (; maxTokens=1000)))))))
                end
                cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode rpc --session-dir $(joinpath(workspace, "sessions")) $args`; dir=workspace)
                cmd = addenv(cmd, "HOME" => workspace, "PI_CODING_AGENT_DIR" => agentdir, "PI_OFFLINE" => "1", "JF_PROVIDER" => "anthropic", "ANTHROPIC_BASE_URL" => base, "ANTHROPIC_API_KEY" => key, "JF_INSTRUCTIONS_DIR" => workspace)
                err = joinpath(agentdir, "error")
                process = open(pipeline(cmd; stderr=err), "r+")
                output = Channel{Any}(Inf)
                reader = @async for line in eachline(process)
                    put!(output, JSON3.read(line, Dict{String, Any}))
                end
                observed = Any[]
                function send(command, predicate)
                    println(process, JSON3.write(command)); flush(process)
                    while true
                        timedwait(() -> isready(output), 45) == :ok || error("RPC timed out")
                        item = take!(output); push!(observed, item)
                        predicate(item) && return item
                    end
                end
                command(value) = send(value, item -> get(item, "id", "") == value.id)
                prompt(id) = send((; id, type="prompt", message="hello"), item -> get(item, "type", "") == "agent_settled")
                function request()
                    timedwait(() -> isready(requests), 10) == :ok || error("No wire request; RPC output: $(JSON3.write(observed)); stderr: $(read(err, String))")
                    take!(requests)
                end
                try
                    levels = command((; id="levels", type="get_available_thinking_levels"))
                    state = command((; id="state", type="get_state"))
                    prompt("start")
                    bodies = [request()]
                    for level in ("off", "minimal", "low", "medium", "high")
                        command((; id=level, type="set_thinking_level", level))
                        prompt(level * "-prompt")
                        push!(bodies, request())
                    end
                    cycle = command((; id="cycle", type="cycle_thinking_level"))
                    prompt("cycled")
                    push!(bodies, request())
                    command((; id="low-again", type="set_thinking_level", level="low"))
                    saved = command((; id="saved", type="get_state"))
                    command((; id="new", type="new_session"))
                    command((; id="switch", type="switch_session", sessionPath=saved["data"]["sessionFile"]))
                    restored = command((; id="restored", type="get_state"))
                    prompt("replay")
                    push!(bodies, request())
                    (; levels, state, cycle, restored, bodies, observed)
                finally
                    close(process.in)
                    timedwait(() -> process_exited(process), 5) == :ok || kill(process)
                    wait(process); wait(reader)
                    @test !occursin(key, read(err, String) * JSON3.write(observed))
                end
            end
            result = runrpc(["--model", "anthropic/$model:high"])
            @test result.levels["data"]["levels"] == ["off", "minimal", "low", "medium", "high"]
            @test result.state["data"]["thinkingLevel"] == "high"
            @test result.cycle["data"]["level"] == "off"
            @test result.restored["data"]["thinkingLevel"] == "high"
            expected = [16384, 0, 1024, 2048, 8192, 16384, 0, 16384]
            wire(body) = get(get(body, "thinking", Dict()), "budget_tokens", 0)
            @test wire.(result.bodies) == expected
            if haskey(ENV, "PI_SOURCE")
                @test readchomp(`git -C $(ENV["PI_SOURCE"]) rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
                piagent = mktempdir(workspace)
                write(joinpath(piagent, "models.json"), JSON3.write((; providers=(; anthropic=(; baseUrl=base, apiKey="synthetic")))))
                oracle = joinpath(@__DIR__, "headless_reference.mjs")
                pi = Cmd(`node $oracle $(ENV["PI_SOURCE"]) --mode rpc --no-session --model anthropic/$model:high --approve`; dir=workspace)
                pi = addenv(pi, "HOME" => workspace, "PI_CODING_AGENT_DIR" => piagent, "PI_OFFLINE" => "1", "ANTHROPIC_API_KEY" => "synthetic")
                input = join(JSON3.write.([(; id="levels", type="get_available_thinking_levels"), (; id="state", type="get_state"), (; id="cycle", type="cycle_thinking_level")]), "\n") * "\n"
                inputpath, outputpath = joinpath(piagent, "input"), joinpath(piagent, "output")
                write(inputpath, input)
                run(pipeline(pi; stdin=inputpath, stdout=outputpath, stderr=devnull))
                replies = Dict(item["id"] => item for item in [JSON3.read(line, Dict{String, Any}) for line in eachline(outputpath)] if get(item, "type", "") == "response" && haskey(item, "id"))
                @test result.levels["data"]["levels"] == replies["levels"]["data"]["levels"]
                @test result.state["data"]["thinkingLevel"] == replies["state"]["data"]["thinkingLevel"]
                @test result.cycle["data"]["level"] == replies["cycle"]["data"]["level"]
                for (body, level) in zip(result.bodies[2:6], ("off", "minimal", "low", "medium", "high"))
                    pi = JSON3.read(read(`node $(joinpath(@__DIR__, "anthropic_thinking_pi.mjs")) $(ENV["PI_SOURCE"]) $model $level`, String), Dict{String, Any})
                    @test get(body, "thinking", nothing) == get(pi["body"], "thinking", nothing)
                end
            end
            resumed = runrpc(["--model", "anthropic/$model"])
            @test resumed.state["data"]["thinkingLevel"] == "medium"
            @test resumed.restored["data"]["thinkingLevel"] == "low"
            @test wire(resumed.bodies[end]) == 2048
            for options in ((; key="sk-ant-oat-synthetic", configured=false), (; key="synthetic-configured", configured=true))
                restricted = runrpc(["--model", "anthropic/$model"]; options...)
                @test restricted.levels["data"]["levels"] == ["off"]
                @test restricted.state["data"]["thinkingLevel"] == "off"
                @test all(body -> !haskey(body, "thinking"), restricted.bodies)
            end
            unsupported = runrpc(["--model", "anthropic/claude-opus-4-6"])
            @test unsupported.levels["data"]["levels"] == ["off"]
            @test all(body -> body["model"] == "claude-opus-4-6" && !haskey(body, "thinking"), unsupported.bodies)
        end
    finally
        close(server); wait(server)
    end
end
