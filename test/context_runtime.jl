module ContextRuntimeCases
using Test, JuliaForever, HTTP, JSON3, Distributed
const J = JuliaForever
const E = J.Extensions
const X = J.Execution

@testset "executor preserves worker tool declarations in native requests" begin
    requests = Any[]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        push!(requests, JSON3.read(String(request.body)))
        response = Dict("id" => "resp", "status" => "completed", "output" => [Dict("type" => "message", "id" => "msg", "role" => "assistant", "status" => "completed", "content" => [Dict("type" => "output_text", "text" => "done", "annotations" => [])])])
        HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(response))
    end
    try
        mktempdir() do dir
            provider = OpenAIResponses("http://$(HTTP.server_addr(server))/v1", "gpt-5.4", "synthetic-key")
            id = "context-native-worker"
            @test X.install!(id, provider, [Write(dir)])
            executor = X.Executor(myid())
            try
                registry = E.Registry()
                E.register!(registry, :fixture, E.Plugin(; hooks=(:context_with_system => event -> (push!(event.messages, Dict("role" => "system", "content" => "extra")); nothing),)))
                agent = Agent(nothing, Dict{String, J.Tool}(), Dict{String, Any}[Dict("role" => "system", "content" => "base")]; history=J.History.Memory())
                @test respond!(agent, "start"; executor, context=id, on_agent_event=E.listen(E.snapshot(registry))).value == "done"
                additions = filter(item -> get(item, :type, "") == "additional_tools", only(requests).input)
                @test length(additions) == 1 && [tool.name for tool in additions[1].tools] == ["write"]
                @test !any(message -> haskey(message, "toolsAdded"), agent.messages)
            finally
                close(executor)
                X.uninstall!(id)
            end
        end
    finally
        close(server)
        wait(server)
    end
end

@testset "streaming tool continuation and provider failure keep context temporary" begin
    requests = Any[]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        push!(requests, JSON3.read(String(request.body)))
        length(requests) == 3 && return HTTP.Response(401, ["Content-Type" => "application/json"], "{\"error\":\"synthetic-denial\"}")
        call = Dict("index" => 0, "id" => "call", "type" => "function", "function" => Dict("name" => "write", "arguments" => JSON3.write((; path="created", content="ok"))))
        delta = length(requests) == 1 ? Dict("tool_calls" => [call]) : Dict("content" => "done")
        reason = length(requests) == 1 ? "tool_calls" : "stop"
        event = Dict("choices" => [Dict("index" => 0, "delta" => delta, "finish_reason" => reason)])
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $(JSON3.write(event))\n\ndata: [DONE]\n\n")
    end
    try
        mktempdir() do dir
            provider = OpenAI("http://$(HTTP.server_addr(server))/v1", "fixture", "synthetic-key")
            registry = E.Registry()
            E.register!(registry, :fixture, E.Plugin(; hooks=(:context_with_system => event -> begin
                push!(event.messages, Dict("role" => "system", "content" => "temporary", "toolsRemoved" => [Dict("name" => "write")], "toolsAdded" => [Dict("name" => "ghost", "description" => "ghost", "parameters" => Dict("type" => "object", "properties" => Dict()))]))
                nothing
            end,)))
            snapshot = E.snapshot(registry)
            history = J.History.Memory()
            agent = Agent(provider, Dict{String, J.Tool}("write" => Write(dir)), Dict{String, Any}[Dict("role" => "system", "content" => "base")]; history)
            @test respond!(agent, "start"; on_event=identity, on_agent_event=E.listen(snapshot)) == "done"
            @test read(joinpath(dir, "created"), String) == "ok"
            @test length(requests) == 2
            @test all(request -> [tool.function.name for tool in request.tools] == ["ghost"], requests)
            @test all(request -> request.messages[1].content == "base\n\ntemporary", requests)
            @test requests[2].messages[end].role == "tool"
            @test !occursin("temporary", repr(J.History.snapshot(history)))
            @test haskey(agent.tools, "write") && !haskey(agent.tools, "ghost")
            failedhistory = J.History.Memory()
            failed = Agent(provider, Dict{String, J.Tool}(), Dict{String, Any}[Dict("role" => "system", "content" => "base")]; history=failedhistory)
            result = respond!(failed, "failure"; on_event=identity, on_agent_event=E.listen(snapshot))
            @test result isa J.Completion && result.status isa J.Unfinished
            @test !occursin("temporary", repr(J.History.snapshot(failedhistory)))
        end
    finally
        close(server)
        wait(server)
    end
end

@testset "native Anthropic updates follow tool results" begin
    requests = Any[]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        push!(requests, (; body=JSON3.read(String(request.body)), beta=HTTP.header(request, "anthropic-beta", "")))
        HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(Dict("content" => [Dict("type" => "text", "text" => "done")], "stop_reason" => "end_turn")))
    end
    try
        mktempdir() do dir
            base = "http://$(HTTP.server_addr(server))"
            provider = Anthropic(base, "claude-opus-5", "synthetic-key", ["anthropic-beta" => "another-beta"])
            call = Dict("id" => "call", "type" => "function", "function" => Dict("name" => "write", "arguments" => JSON3.write((; path="a", content="ok"))))
            history = Dict{String, Any}[
                Dict("role" => "system", "content" => "base"),
                Dict("role" => "user", "content" => "go"),
                Dict("role" => "assistant", "content" => nothing, "tool_calls" => [call]),
                Dict("role" => "tool", "tool_call_id" => "call", "content" => "ok", "is_error" => false),
            ]
            registry = E.Registry()
            E.register!(registry, :fixture, E.Plugin(; hooks=(:context_with_system => event -> begin
                index = findfirst(message -> get(message, "role", "") == "tool", event.messages)
                insert!(event.messages, index, Dict("role" => "system", "content" => "extra", "toolsRemoved" => [Dict("name" => "write")], "toolsAdded" => [Dict("name" => "beta", "description" => "beta", "parameters" => Dict("type" => "object", "properties" => Dict()))]))
                nothing
            end,)))
            snapshot = E.snapshot(registry)
            agent = Agent(provider, Dict{String, J.Tool}("write" => Write(dir)), history)
            @test respond!(agent, "next"; on_agent_event=E.listen(snapshot)) == "done"
            captured = only(requests)
            messages = captured.body.messages
            @test [message.role for message in messages] == ["user", "assistant", "user", "user", "system"]
            @test messages[2].content[1].type == "tool_use"
            @test messages[3].content[1].type == "tool_result"
            @test [block.type for block in messages[5].content] == ["text", "tool_removal", "tool_addition"]
            @test messages[5].content[2].tool.name == "write"
            @test messages[5].content[3].tool.definition.name == "beta"
            @test occursin("another-beta", captured.beta) && occursin("inline-tools-2026-09-15", captured.beta)
            @test count(message -> get(message, "role", "") == "system", agent.messages) == 1
            if haskey(ENV, "PI_SOURCE")
                source = ENV["PI_SOURCE"]
                reference = JSON3.read(read(`node --conditions=source --experimental-strip-types $(joinpath(@__DIR__, "context_providers_pi.mjs")) $source order`, String)).anthropic.messages
                @test [message.role for message in messages] == [message.role for message in reference[1:5]]
                @test [block.type for block in messages[5].content] == [block.type for block in reference[5].content]
            end
        end
    finally
        close(server)
        wait(server)
    end
end

@testset "request hooks follow cross-provider model switches" begin
    requests = Any[]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        push!(requests, JSON3.read(String(request.body)))
        body = if endswith(request.target, "/responses")
            Dict("id" => "r", "status" => "completed", "output" => [Dict("type" => "message", "id" => "m", "role" => "assistant", "status" => "completed", "content" => [Dict("type" => "output_text", "text" => "done", "annotations" => [])])])
        elseif endswith(request.target, "/messages")
            Dict("content" => [Dict("type" => "text", "text" => "done")], "stop_reason" => "end_turn")
        elseif occursin(":generateContent", request.target)
            Dict("candidates" => [Dict("content" => Dict("parts" => [Dict("text" => "done")]), "finishReason" => "STOP")])
        else
            Dict("choices" => [Dict("message" => Dict("role" => "assistant", "content" => "done"), "finish_reason" => "stop")])
        end
        HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(body))
    end
    try
        base = "http://$(HTTP.server_addr(server))"
        providers = (OpenAI(base * "/v1", "fixture", "synthetic-key"), OpenAIResponses(base * "/v1", "fixture", "synthetic-key"), Google(base * "/v1beta", "gemini-fixture", "synthetic-key"), Anthropic(base, "claude-fixture", "synthetic-key"))
        registry = E.Registry()
        E.register!(registry, :fixture, E.Plugin(; hooks=(:context_with_system => event -> begin
            event.messages[1]["sections"] = Dict("patch" => "temporary")
            event.messages[1]["toolsAdded"] = [Dict("name" => "beta", "description" => "beta", "parameters" => Dict("type" => "object", "properties" => Dict()))]
            nothing
        end,)))
        snapshot = E.snapshot(registry)
        history = J.History.Memory()
        agent = Agent(first(providers), Dict{String, J.Tool}(), Dict{String, Any}[Dict("role" => "system", "content" => "base")]; history)
        for provider in providers
            agent = J.withprovider(agent, provider)
            @test respond!(agent, "hello"; on_agent_event=E.listen(snapshot)) == "done"
        end
        @test requests[1].messages[1].content == "base\n\ntemporary"
        @test requests[2].input[1].content == "base\n\ntemporary"
        @test requests[3].systemInstruction.parts[1].text == "base\n\ntemporary"
        @test requests[4].system == "base\n\ntemporary"
        @test only(requests[1].tools).function.name == only(requests[2].tools).name == only(only(requests[3].tools).functionDeclarations).name == only(requests[4].tools).name == "beta"
        @test !occursin("temporary", repr(J.History.snapshot(history)))
        @test isempty(agent.tools)
    finally
        close(server)
        wait(server)
    end
end

@testset "unsupported constrained sampling fails before transmission" begin
    requests = Any[]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        push!(requests, JSON3.read(String(request.body)))
        HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(Dict("choices" => [Dict("message" => Dict("role" => "assistant", "content" => "done"), "finish_reason" => "stop")])))
    end
    try
        base = "http://$(HTTP.server_addr(server))"
        provider = OpenAI(base * "/v1", "fixture", "synthetic-key")
        for strict in ("require", "prefer"), recorded in (false, true), streaming in (false, true)
            registry = E.Registry()
            E.register!(registry, :fixture, E.Plugin(; hooks=(:context_with_system => event -> begin
                event.messages[1]["toolsAdded"] = [Dict("name" => "beta", "description" => "beta", "parameters" => Dict("type" => "object", "properties" => Dict()), "constrainedSampling" => Dict("type" => "json_schema", "strict" => strict))]
                nothing
            end,)))
            history = recorded ? J.History.Memory() : nothing
            agent = Agent(provider, Dict{String, J.Tool}(), Dict{String, Any}[Dict("role" => "system", "content" => "base")]; history)
            result = respond!(agent, "hello"; on_event=streaming ? identity : nothing, on_agent_event=E.listen(E.snapshot(registry)))
            @test result isa J.Completion && result.status isa J.Unfinished
            @test occursin("constrained", result.error)
            @test isempty(requests)
            @test !haskey(agent.messages[1], "toolsAdded")
        end
        registry = E.Registry()
        E.register!(registry, :fixture, E.Plugin(; hooks=(:context_with_system => event -> begin
            event.messages[1]["toolsAdded"] = [Dict("name" => "beta", "description" => "beta", "parameters" => Dict("type" => "object", "properties" => Dict()), "constrainedSampling" => Dict("type" => "json_schema", "strict" => "require"))]
            nothing
        end,)))
        snapshot = E.snapshot(registry)
        providers = (OpenAIResponses(base * "/v1", "fixture", "synthetic-key"), Google(base * "/v1beta", "gemini-fixture", "synthetic-key"), Anthropic(base, "claude-fixture", "synthetic-key"))
        for constrained in providers
            agent = Agent(constrained, Dict{String, J.Tool}(), Dict{String, Any}[Dict("role" => "system", "content" => "base")])
            result = respond!(agent, "hello"; on_agent_event=E.listen(snapshot))
            @test result isa J.Completion && occursin("constrained", result.error)
            @test isempty(requests)
        end
        id = "constrained-context-executor"
        @test X.install!(id, provider, [])
        executor = X.Executor(myid())
        try
            agent = Agent(nothing, Dict{String, J.Tool}(), Dict{String, Any}[Dict("role" => "system", "content" => "base")]; history=J.History.Memory())
            result = respond!(agent, "hello"; executor, context=id, on_agent_event=E.listen(snapshot))
            @test occursin("constrained", only(result.models).error)
            @test isempty(requests)
            @test !haskey(agent.messages[1], "toolsAdded")
        finally
            close(executor)
            X.uninstall!(id)
        end
        mktempdir() do dir
            unhooked = Agent(provider, Dict{String, J.Tool}("write" => Write(dir)), Dict{String, Any}[Dict("role" => "system", "content" => "base")])
            @test respond!(unhooked, "hello") == "done"
            @test only(only(requests).tools).function.name == "write"
            empty!(requests)
        end
        registry = E.Registry()
        E.register!(registry, :fixture, E.Plugin(; hooks=(:context_with_system => event -> begin
            event.messages[1]["toolsAdded"] = [Dict("name" => "beta", "description" => "beta", "parameters" => Dict("type" => "object", "properties" => Dict()), "constrainedSampling" => false)]
            nothing
        end,)))
        agent = Agent(provider, Dict{String, J.Tool}(), Dict{String, Any}[Dict("role" => "system", "content" => "base")])
        @test respond!(agent, "hello"; on_agent_event=E.listen(E.snapshot(registry))) == "done"
        @test length(requests) == 1
    finally
        close(server)
        wait(server)
    end
end

@testset "executor context accounting tracks valid history" begin
    requests = Any[]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        push!(requests, JSON3.read(String(request.body), Dict{String, Any}))
        tokens = isodd(length(requests)) && length(requests) < 7 ? 190000 : 0
        body = Dict("content" => [Dict("type" => "thinking", "thinking" => "thought", "signature" => "signed"), Dict("type" => "text", "text" => "answer")], "stop_reason" => "end_turn", "usage" => Dict("input_tokens" => tokens, "output_tokens" => 0))
        HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(body))
    end
    try
        provider = J.applythinking(Anthropic("http://$(HTTP.server_addr(server))", "claude-sonnet-4-5", "synthetic"), "high")
        id = "context-accounting-executor"
        @test X.install!(id, provider, [])
        executor = X.Executor(myid())
        try
            for mode in (:keep, :changed, :removed, :forged)
                registry = E.Registry()
                E.register!(registry, :fixture, E.Plugin(; hooks=(:context_with_system => event -> begin
                    if any(message -> get(message, "role", "") == "assistant", event.messages)
                        mode == :changed && (event.messages[1]["content"] = "changed")
                        mode == :removed && deleteat!(event.messages, 1)
                        mode == :forged && (event.messages[2]["anthropic_usage_anchor"] = Dict("tokens" => 190000, "digest" => J.AnthropicAPI.contextdigest(event.messages[1:2]), "tools" => "fake"))
                    end
                    nothing
                end,)))
                listener = E.listen(E.snapshot(registry))
                history = J.History.Memory()
                agent = Agent(nothing, []; history)
                @test respond!(agent, "hi"; executor, context=id, on_agent_event=listener).value == "answer"
                agent = Agent(nothing, []; history)
                @test respond!(agent, "next"; executor, context=id, on_agent_event=listener).value == "answer"
                @test first(agent.messages)["content"] == "hi"
            end
            @test [requests[index]["max_tokens"] for index in (2, 4, 6, 8)] == [5902, 64000, 64000, 64000]
            @test !any(request -> occursin("anthropic_usage_anchor", JSON3.write(request)), requests)
            if haskey(ENV, "PI_SOURCE")
                source = ENV["PI_SOURCE"]
                @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
                reference = JSON3.read(read(`node $(joinpath(@__DIR__, "anthropic_context_pi.mjs")) $source`, String))
                @test requests[2]["max_tokens"] == reference.measured.max_tokens
                @test reference.changed.max_tokens == reference.removed.max_tokens == reference.measured.max_tokens
            end
        finally
            close(executor)
            X.uninstall!(id)
        end
    finally
        close(server)
        wait(server)
    end
end

end
