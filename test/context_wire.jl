module ContextWireCases
using Test, JuliaForever, HTTP, JSON3, OrderedCollections
const J = JuliaForever
const E = J.Extensions

@testset "hook prompt sections reach provider requests" begin
    requests = Any[]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        push!(requests, JSON3.read(String(request.body)))
        if occursin("text/event-stream", HTTP.header(request, "Accept"))
            chunk = Dict("choices" => [Dict("index" => 0, "delta" => Dict("content" => "done"), "finish_reason" => "stop")])
            return HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $(JSON3.write(chunk))\n\ndata: [DONE]\n\n")
        end
        body = occursin("generateContent", request.target) ? Dict("candidates" => [Dict("content" => Dict("parts" => [Dict("text" => "done")]), "finishReason" => "STOP")]) : Dict("choices" => [Dict("message" => Dict("role" => "assistant", "content" => "done"), "finish_reason" => "stop")])
        HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(body))
    end
    try
        base = "http://$(HTTP.server_addr(server))"
        registry = E.Registry()
        E.register!(registry, :fixture, E.Plugin(; hooks=(:context_with_system => (e -> (e.messages[1]["sections"] = Dict("rules" => "new rules"); nothing)),)))
        for provider in (OpenAI(base * "/v1", "fixture", "synthetic"), Google(base * "/v1beta", "gemini-fixture", "synthetic"))
            agent = Agent(provider, E.snapshot(registry), Dict{String, Any}[Dict("role" => "system", "content" => "base")])
            @test respond!(agent, "hello"; on_agent_event=E.listen(E.snapshot(registry))) == "done"
            @test !haskey(agent.messages[1], "sections")
        end
        @test requests[1].messages[1].content == "base\n\nnew rules"
        @test requests[2].systemInstruction.parts[1].text == "base\n\nnew rules"
        if haskey(ENV, "PI_SOURCE")
            source = ENV["PI_SOURCE"]
            @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
            run(`node $(joinpath(@__DIR__, "context_wire_pi.mjs")) $source $base`)
            @test requests[3].messages[1].content == requests[1].messages[1].content
        end
    finally
        close(server)
        wait(server)
    end
end
@testset "system patch wire parity checkpoint" begin
    if haskey(ENV, "PI_SOURCE")
        source = ENV["PI_SOURCE"]
        @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
        requests = Any[]
        server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
            push!(requests, JSON3.read(String(request.body)))
            if occursin("text/event-stream", HTTP.header(request, "Accept"))
                chunk = Dict("choices" => [Dict("index" => 0, "delta" => Dict("content" => "done"), "finish_reason" => "stop")])
                return HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $(JSON3.write(chunk))\n\ndata: [DONE]\n\n")
            end
            HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(Dict("choices" => [Dict("message" => Dict("role" => "assistant", "content" => "done"), "finish_reason" => "stop")])))
        end
        try
            base = "http://$(HTTP.server_addr(server))"
            tool(name) = Dict("name" => name, "description" => name, "parameters" => Dict("type" => "object", "properties" => Dict()))
            registry = E.Registry()
            function patch(e)
                e.messages[1]["sections"] = OrderedDict("zebra" => "first", "apple" => "old")
                e.messages[1]["toolsAdded"] = [tool("alpha")]
                push!(e.messages, Dict("role" => "system", "content" => "extra", "sections" => OrderedDict("apple" => "new", "zebra" => nothing, "banana" => "last"), "toolsRemoved" => [Dict("name" => "alpha")], "toolsAdded" => [tool("beta")], "timestamp" => 1))
                nothing
            end
            E.register!(registry, :patch, E.Plugin(; hooks=(:context_with_system => patch,)))
            snapshot = E.snapshot(registry)
            agent = Agent(OpenAI(base * "/v1", "fixture", "synthetic"), snapshot, Dict{String, Any}[Dict("role" => "system", "content" => "base", "timestamp" => 0)])
            @test respond!(agent, "hello"; on_agent_event=E.listen(snapshot)) == "done"
            run(`node $(joinpath(@__DIR__, "context_patch_wire_pi.mjs")) $source $base`)
            native, pi = requests
            @test pi.messages[1].content == "base\n\nextra\n\nnew\n\nlast"
            @test [t.function.name for t in pi.tools] == ["beta"]
            @test native.messages == pi.messages
            @test haskey(native, :tools) && [t.function.name for t in native.tools] == ["beta"]
            @test !haskey(agent.messages[1], "sections")
            @test isempty(agent.tools)
        finally
            close(server)
            wait(server)
        end
    end
end

end
