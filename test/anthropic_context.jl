using Test, JuliaForever, HTTP, JSON3

@testset "Anthropic context accounting" begin
    requests = Channel{Any}(12)
    replies = Channel{Any}(12)
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        body = JSON3.read(String(request.body), Dict{String, Any})
        put!(requests, body)
        reply = take!(replies)
        if get(body, "stream", false)
            events = [Dict("type" => "message_start", "message" => Dict("usage" => reply["usage"])), Dict("type" => "content_block_start", "index" => 0, "content_block" => reply["content"][1]), Dict("type" => "content_block_stop", "index" => 0), Dict("type" => "content_block_start", "index" => 1, "content_block" => reply["content"][2]), Dict("type" => "content_block_stop", "index" => 1), Dict("type" => "message_delta", "delta" => Dict("stop_reason" => "end_turn")), Dict("type" => "message_stop")]
            return HTTP.Response(200, ["Content-Type" => "text/event-stream"], join("data: $(JSON3.write(event))\n\n" for event in events))
        end
        HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(reply))
    end
    answer(thought, tokens) = Dict("content" => [Dict("type" => "thinking", "thinking" => thought, "signature" => "signed"), Dict("type" => "text", "text" => "answer")], "stop_reason" => "end_turn", "usage" => Dict("input_tokens" => tokens, "output_tokens" => 0))
    try
        provider = JuliaForever.applythinking(Anthropic("http://$(HTTP.server_addr(server))", "claude-sonnet-4-5", "synthetic-secret"), "high")
        reference = if haskey(ENV, "PI_SOURCE")
            @test readchomp(`git -C $(ENV["PI_SOURCE"]) rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
            JSON3.read(read(`node $(joinpath(@__DIR__, "anthropic_context_pi.mjs")) $(ENV["PI_SOURCE"])`, String), Dict{String, Any})
        else
            Dict("measured" => Dict("max_tokens" => 5902, "thinking" => Dict("type" => "enabled", "budget_tokens" => 4878, "display" => "summarized")), "estimated" => Dict("max_tokens" => 53042, "thinking" => Dict("type" => "enabled", "budget_tokens" => 16384, "display" => "summarized")), "switched" => Dict("max_tokens" => 5902, "assistant" => [Dict("type" => "text", "text" => "answer")]), "off" => Dict("max_tokens" => 5902, "thinking" => Dict("type" => "disabled")))
        end

        history = JuliaForever.History.Memory()
        agent = Agent(provider, []; history)
        put!(replies, answer("thought", 190000))
        @test respond!(agent, "hi") == "answer"
        take!(requests)
        restored = Agent(provider, []; history)
        put!(replies, answer("thought", 0))
        @test respond!(restored, "next") == "answer"
        measured = take!(requests)
        @test measured["max_tokens"] == reference["measured"]["max_tokens"]
        @test measured["thinking"] == reference["measured"]["thinking"]
        @test measured["messages"][2]["content"][1] == Dict("type" => "thinking", "thinking" => "thought", "signature" => "signed")
        @test !occursin("synthetic-secret", JSON3.write(history.batches))
        @test !occursin("anthropic_usage_anchor", JSON3.write(measured))

        if Sys.isunix()
            mktempdir() do dir
                path = joinpath(dir, "history.jsonl")
                store = open(JuliaForever.Durable.Store, path)
                recorded = JuliaForever.History.create(store)
                id = recorded.id
                try
                    journaled = Agent(provider, []; history=recorded)
                    put!(replies, answer("thought", 190000))
                    @test respond!(journaled, "hi") == "answer"
                    take!(requests)
                finally
                    close(store)
                end
                store = open(JuliaForever.Durable.Store, path)
                try
                    replayed = Agent(provider, []; history=JuliaForever.History.Journal(store, id))
                    put!(replies, answer("thought", 0))
                    @test respond!(replayed, "next") == "answer"
                    @test take!(requests)["max_tokens"] == reference["measured"]["max_tokens"]
                finally
                    close(store)
                end
            end
        end

        switchedprovider = JuliaForever.modelchange(provider, "claude-haiku-4-5", provider.route)
        switched = Agent(switchedprovider, [], deepcopy(agent.state.messages))
        put!(replies, answer("thought", 0))
        @test respond!(switched, "next") == "answer"
        switchedrequest = take!(requests)
        @test switchedrequest["max_tokens"] == reference["switched"]["max_tokens"]
        @test switchedrequest["messages"][2]["content"] == reference["switched"]["assistant"]

        offprovider = JuliaForever.applythinking(provider, "off")
        offagent = Agent(offprovider, [], deepcopy(agent.state.messages))
        put!(replies, answer("thought", 0))
        @test respond!(offagent, "next") == "answer"
        offrequest = take!(requests)
        @test offrequest["max_tokens"] == reference["off"]["max_tokens"]
        @test offrequest["thinking"] == reference["off"]["thinking"]

        chat = JSON3.read(JuliaForever.payload(OpenAI("https://example.invalid", "synthetic", "synthetic"), agent.messages, Dict(), Dict()), Dict{String, Any})
        @test !occursin("anthropic_usage_anchor", JSON3.write(chat))

        changed = deepcopy(agent.state.messages)
        changed[1] = JuliaForever.Conversation.User("changed")
        altered = Agent(provider, [], changed)
        put!(replies, answer("thought", 0))
        @test respond!(altered, "next") == "answer"
        @test take!(requests)["max_tokens"] == 64000

        untrusted = Agent(provider, [], deepcopy(agent.messages))
        put!(replies, answer("thought", 0))
        @test respond!(untrusted, "next") == "answer"
        @test take!(requests)["max_tokens"] == 64000

        malformed = deepcopy(agent.state.messages)
        malformed[2].metadata["anthropic_usage_anchor"] = Dict("tokens" => "not a count", "digest" => "bad", "tools" => "bad")
        malformedagent = Agent(provider, [], malformed)
        put!(replies, answer("thought", 0))
        @test respond!(malformedagent, "next") == "answer"
        @test take!(requests)["max_tokens"] == 64000

        stale = deepcopy(agent.state.messages)
        for _ in 1:5
            push!(stale, JuliaForever.Conversation.User("middle"))
            metadata = Dict("anthropic_usage_anchor" => Dict("tokens" => 150000, "digest" => repeat("0", 64), "tools" => repeat("0", 64)))
            push!(stale, JuliaForever.Conversation.Assistant("answer", JuliaForever.Conversation.ToolCall[], "stop", true; metadata))
        end
        staleagent = Agent(provider, [], stale)
        put!(replies, answer("thought", 0))
        @test respond!(staleagent, "next") == "answer"
        @test take!(requests)["max_tokens"] == reference["measured"]["max_tokens"] - 20

        modifiedtools = Agent(provider, [Read(pwd())], deepcopy(agent.state.messages))
        put!(replies, answer("thought", 0))
        @test respond!(modifiedtools, "next") == "answer"
        @test 1 < take!(requests)["max_tokens"] < reference["measured"]["max_tokens"]

        streaming = Agent(provider, [])
        put!(replies, answer("thought", 190000))
        @test respond!(streaming, "hi"; on_event=identity) == "answer"
        take!(requests)
        put!(replies, answer("thought", 192000))
        @test respond!(streaming, "next"; on_event=identity) == "answer"
        @test take!(requests)["max_tokens"] == reference["measured"]["max_tokens"]
        put!(replies, answer("thought", 0))
        @test respond!(streaming, "third"; on_event=identity) == "answer"
        @test take!(requests)["max_tokens"] == 3902

        execution = JuliaForever.Execution
        conversation = JuliaForever.Conversation
        context = "anthropic-context-$(objectid(server))"
        @test execution.install!(context, provider, [])
        try
            messages = conversation.Message[conversation.User("hi")]
            put!(replies, answer("thought", 190000))
            first = execution.perform(execution.Work(context, conversation.ModelRequest(messages); detailed=true), execution.Cancellation())
            take!(requests)
            push!(messages, first.observation.message, conversation.User("next"))
            put!(replies, answer("thought", 0))
            second = execution.perform(execution.Work(context, conversation.ModelRequest(messages); detailed=true), execution.Cancellation())
            @test second.observation.message.content == "answer"
            @test take!(requests)["max_tokens"] == reference["measured"]["max_tokens"]
        finally
            execution.uninstall!(context)
        end

        mktempdir() do dir
            write(joinpath(dir, "input.txt"), "data")
            call = Dict("type" => "tool_use", "id" => "read-1", "name" => "read", "input" => Dict("path" => "input.txt"))
            put!(replies, Dict("content" => [Dict("type" => "thinking", "thinking" => "thought", "signature" => "signed"), call], "stop_reason" => "tool_use", "usage" => Dict("input_tokens" => 190000, "output_tokens" => 0)))
            put!(replies, answer("thought", 0))
            toolagent = Agent(provider, [Read(dir)])
            @test respond!(toolagent, "hi") == "answer"
            take!(requests)
            toolrequest = take!(requests)
            @test 5800 < toolrequest["max_tokens"] <= reference["measured"]["max_tokens"]
            @test toolrequest["messages"][2]["content"][2]["id"] == "read-1"
            @test toolrequest["messages"][3]["content"][1]["tool_use_id"] == "read-1"
        end

        agent = Agent(provider, [])
        put!(replies, answer(repeat("x", 500000), 0))
        @test respond!(agent, "hi") == "answer"
        take!(requests)
        put!(replies, answer("thought", 0))
        @test respond!(agent, "next") == "answer"
        estimated = take!(requests)
        @test estimated["max_tokens"] == reference["estimated"]["max_tokens"]
        @test estimated["thinking"] == reference["estimated"]["thinking"]
    finally
        close(server); wait(server)
    end
end
