using Test, JuliaForever, HTTP, JSON3

@testset "Anthropic streaming, thinking, switching and replay" begin
    requests = Channel{Any}(30)
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        body = JSON3.read(String(request.body), Dict{String, Any})
        put!(requests, (; body, target=request.target, key=HTTP.header(request, "x-api-key", ""), beta=HTTP.header(request, "anthropic-beta", "")))
        content = [Dict("type" => "thinking", "thinking" => "thought", "signature" => "signed"), Dict("type" => "text", "text" => "answer")]
        usage = Dict("input_tokens" => 190000, "output_tokens" => 0)
        if get(body, "stream", false)
            events = [Dict("type" => "message_start", "message" => Dict("usage" => usage)), Dict("type" => "content_block_start", "index" => 0, "content_block" => content[1]), Dict("type" => "content_block_stop", "index" => 0), Dict("type" => "content_block_start", "index" => 1, "content_block" => content[2]), Dict("type" => "content_block_stop", "index" => 1), Dict("type" => "message_delta", "delta" => Dict("stop_reason" => "end_turn")), Dict("type" => "message_stop")]
            return HTTP.Response(200, ["Content-Type" => "text/event-stream"], join("data: $(JSON3.write(event))\n\n" for event in events))
        end
        HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(Dict("content" => content, "stop_reason" => "end_turn", "usage" => usage)))
    end
    try
        mktempdir() do dir
            base = "http://$(HTTP.server_addr(server))"
            id = "claude-sonnet-4-5"
            input = [Dict("role" => "user", "content" => "hello")]
            tools = Dict("read" => Read(dir))
            expected = if haskey(ENV, "PI_SOURCE")
                source = ENV["PI_SOURCE"]
                @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
                JSON3.read(read(`node $(joinpath(@__DIR__, "anthropic_eager_pi.mjs")) $source`, String), Vector{Dict{String, Any}})
            else
                [Dict("eager" => eager, "level" => level, "exposed" => exposed, "beta" => join([(!eager && exposed ? ["fine-grained-tool-streaming-2025-05-14"] : []); (level == "high" ? ["interleaved-thinking-2025-05-14"] : [])], ","), "body" => Dict("thinking" => (level == "high" ? Dict("type" => "enabled", "budget_tokens" => 16384, "display" => "summarized") : Dict("type" => "disabled")))) for eager in (true, false) for level in ("off", "high") for exposed in (true, false)]
            end
            for case in expected
                eager, level, exposed = case["eager"], case["level"], case["exposed"]
                model = JuliaForever.applythinking(Anthropic(base, id, "synthetic-secret"; eager_tool_streaming=eager), level)
                @test JuliaForever.stream(model, input, exposed ? tools : Dict()).done
                wire = take!(requests)
                @test wire.key == "synthetic-secret" && wire.target == "/v1/messages"
                @test wire.beta == something(case["beta"], "")
                @test wire.body["thinking"] == case["body"]["thinking"]
                @test haskey(wire.body, "tools") == exposed
                exposed && @test get(only(wire.body["tools"]), "eager_input_streaming", false) == eager
                switched = JuliaForever.modelchange(model, "claude-haiku-4-5", model.route)
                @test JuliaForever.complete(switched, input, tools).done
                switchedwire = take!(requests)
                @test switchedwire.body["model"] == "claude-haiku-4-5"
                @test switchedwire.key == "synthetic-secret"
                @test get(only(switchedwire.body["tools"]), "eager_input_streaming", false) == eager
                @test switchedwire.beta == join([(!eager ? ["fine-grained-tool-streaming-2025-05-14"] : []); (level == "high" ? ["interleaved-thinking-2025-05-14"] : [])], ",")
            end
            builtin = Anthropic("https://api.anthropic.com", id, "synthetic-secret")
            unknown = JuliaForever.modelchange(builtin, "custom", builtin.route)
            restored = JuliaForever.modelchange(unknown, id, unknown.route)
            has_eager(model) = get(only(JSON3.read(JuliaForever.payload(model, input, tools, Dict()), Dict{String, Any})["tools"]), "eager_input_streaming", false)
            @test has_eager(builtin) && !has_eager(unknown) && has_eager(restored)
            @test !has_eager(Anthropic(base, id, "synthetic-secret"))
            custom = Anthropic(base, id, "synthetic-secret", ["AnThRoPiC-BeTa" => "custom-beta"]; eager_tool_streaming=false)
            @test JuliaForever.stream(custom, input, tools).done
            @test take!(requests).beta == "custom-beta"

            path = joinpath(dir, "models.json")
            write(path, JSON3.write((; providers=(; fixture=(; baseUrl=base * "/configured", api="anthropic-messages", apiKey="configured-secret", models=[(; id="first"), (; id="second")])))))
            registry = JuliaForever.Models.load(path)
            info = JuliaForever.configuredinfo(registry, "fixture", "first", ENV)
            selected = JuliaForever.acquire(JuliaForever.APIKeyAuth(), info, "first")
            for eager in (true, false)
                routed = Anthropic(base * "/wrong", "first", "wrong-secret", Pair{String, String}[], selected.route; eager_tool_streaming=eager)
                switched = JuliaForever.modelchange(routed, "second", routed.route)
                @test JuliaForever.stream(switched, input, tools).done
                configured = take!(requests)
                @test (configured.target, configured.key, configured.body["model"]) == ("/configured/v1/messages", "configured-secret", "second")
                @test get(only(configured.body["tools"]), "eager_input_streaming", false) == eager
                @test configured.beta == (eager ? "" : "fine-grained-tool-streaming-2025-05-14")
                @test !occursin("wrong-secret", repr(switched) * JSON3.write(switched))
                @test !occursin("configured-secret", repr(switched) * JSON3.write(switched))
            end

            for eager in (true, false)
                rpc = JuliaForever.Headless
                terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), ["synthetic-secret"], JuliaForever.RPCMode("anthropic", "high"))
                agent = Agent(Anthropic(base, id, "synthetic-secret"; eager_tool_streaming=eager), [Read(dir)])
                extensions = JuliaForever.Extensions.snapshot(JuliaForever.Extensions.Registry())
                session = rpc.Session(terminal, agent, extensions, Ref(nothing), Dict(), dir)
                for level in ("high", "off", "high")
                    rpc.respond!(session, rpc.request(JSON3.write((; id="level", type="set_thinking_level", level))))
                    rpc.respond!(session, rpc.request(JSON3.write((; id="prompt", type="prompt", message="hello"))))
                    timedwait(() -> isready(requests), 10) == :ok || error("No RPC provider request")
                    wire = take!(requests)
                    timedwait(() -> lock(() -> session.task === nothing, session.lock), 10) == :ok || error("RPC did not settle")
                    @test get(only(wire.body["tools"]), "eager_input_streaming", false) == eager
                    @test wire.beta == join([(!eager ? ["fine-grained-tool-streaming-2025-05-14"] : []); (level == "high" ? ["interleaved-thinking-2025-05-14"] : [])], ",")
                    @test wire.body["thinking"]["type"] == (level == "high" ? "enabled" : "disabled")
                end
                rpc.respond!(session, rpc.request(JSON3.write((; id="stats", type="get_session_stats"))))
                output = String(take!(terminal.output))
                events = [JSON3.read(line, Dict{String, Any}) for line in eachline(IOBuffer(output))]
                @test count(event -> get(event, "type", "") == "response" && get(event, "success", false), events) == 6
                assistants = [event["message"] for event in events if get(event, "type", "") == "message_end" && get(event["message"], "role", "") == "assistant"]
                @test [message["usage"]["input"] for message in assistants] == fill(190000, 3)
                statistics = only(event for event in events if get(event, "id", "") == "stats")
                @test !statistics["success"] && occursin("unavailable", statistics["error"])
                @test !occursin("synthetic-secret", output * String(take!(terminal.diagnostics)))
            end

            if Sys.isunix()
                journalpath = joinpath(dir, "history.jsonl")
                store = open(JuliaForever.Durable.Store, journalpath)
                recorded = JuliaForever.History.create(store)
                session = recorded.id
                eager = JuliaForever.applythinking(Anthropic(base, id, "synthetic-secret"; eager_tool_streaming=true), "high")
                legacy = JuliaForever.applythinking(Anthropic(base, id, "synthetic-secret"; eager_tool_streaming=false), "high")
                try
                    agent = Agent(eager, [Read(dir)]; history=recorded)
                    @test respond!(agent, "hello"; on_event=identity) == "answer"
                    take!(requests)
                    assistant = agent.state.messages[2]
                    @test assistant.info.usage.input == 190000
                    @test assistant.info.api == "anthropic-messages" && assistant.info.model == id
                    @test haskey(assistant.metadata, "anthropic_usage_anchor")
                finally
                    close(store)
                end
                store = open(JuliaForever.Durable.Store, journalpath)
                try
                    replayed = Agent(eager, [Read(dir)]; history=JuliaForever.History.Journal(store, session))
                    assistant = replayed.state.messages[2]
                    @test assistant.info.usage.input == 190000
                    @test assistant.info.api == "anthropic-messages" && assistant.info.model == id
                    @test haskey(assistant.metadata, "anthropic_usage_anchor")
                    original = deepcopy(replayed.state.messages)
                    same = Agent(eager, [Read(dir)], deepcopy(original))
                    changed = Agent(legacy, [Read(dir)], deepcopy(original))
                    switchedprovider = JuliaForever.modelchange(eager, "claude-haiku-4-5", eager.route)
                    switchedagent = Agent(switchedprovider, [Read(dir)], deepcopy(original))
                    pi = if haskey(ENV, "PI_SOURCE")
                        JSON3.read(read(`node $(joinpath(@__DIR__, "anthropic_eager_replay_pi.mjs")) $(ENV["PI_SOURCE"])`, String), Dict{String, Any})
                    else
                        Dict("same" => Dict("max_tokens" => 5902, "thinking" => Dict("type" => "enabled", "budget_tokens" => 4878, "display" => "summarized"), "assistant" => [Dict("type" => "thinking", "thinking" => "thought", "signature" => "signed"), Dict("type" => "text", "text" => "answer")], "eager" => true), "switched" => Dict("max_tokens" => 5902, "thinking" => Dict("type" => "enabled", "budget_tokens" => 4878, "display" => "summarized"), "assistant" => [Dict("type" => "text", "text" => "answer")], "eager" => true))
                    end
                    @test respond!(same, "next"; on_event=identity) == "answer"
                    samewire = take!(requests)
                    @test respond!(changed, "next"; on_event=identity) == "answer"
                    changedwire = take!(requests)
                    @test respond!(switchedagent, "next"; on_event=identity) == "answer"
                    switchedwire = take!(requests)
                    for (wire, reference) in ((samewire, pi["same"]), (switchedwire, pi["switched"]))
                        @test wire.body["max_tokens"] == reference["max_tokens"]
                        @test wire.body["thinking"] == reference["thinking"]
                        @test wire.body["messages"][2]["content"] == reference["assistant"]
                        @test wire.body["tools"][1]["eager_input_streaming"] == reference["eager"]
                    end
                    if haskey(pi, "custom")
                        @test pi["custom"] && !has_eager(Anthropic(base, "custom-model", "synthetic-secret"))
                        @test pi["custombeta"] == "custom-beta"
                    end
                    @test samewire.body["max_tokens"] > changedwire.body["max_tokens"]
                    @test changedwire.body["messages"][2]["content"][1]["signature"] == "signed"
                    @test changedwire.beta == "fine-grained-tool-streaming-2025-05-14,interleaved-thinking-2025-05-14"
                    @test !occursin("synthetic-secret", read(journalpath, String))
                    @test !occursin("anthropic_usage_anchor", JSON3.write(changedwire.body))
                    @test !occursin("responseInfo", JSON3.write(changedwire.body))
                finally
                    close(store)
                end
            end
        end
    finally
        close(server); wait(server)
    end
end
