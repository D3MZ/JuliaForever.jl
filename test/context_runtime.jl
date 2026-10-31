module ContextRuntimeCases
using Test, JuliaForever, HTTP, JSON3, Distributed
const J = JuliaForever
const E = J.Extensions
const X = J.Execution

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
