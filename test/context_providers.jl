module ContextProviderCases

using Test, JuliaForever, HTTP, JSON3, OrderedCollections, Distributed
const J = JuliaForever
const E = J.Extensions

tool(name) = Dict("name" => name, "description" => name, "parameters" => Dict("type" => "object", "properties" => Dict("kind" => Dict("const" => "synthetic"), "const" => Dict("const" => 7), "flag" => Dict("const" => true), "existing" => Dict("const" => 5, "enum" => [5, 6]), "nested" => Dict("default" => Dict("const" => "literal"), "items" => Dict("const" => "inner")))))
function patch(event)
    event.messages[1]["sections"] = OrderedDict("zebra" => "first", "apple" => "old")
    event.messages[1]["toolsAdded"] = [tool("alpha")]
    push!(event.messages, Dict("role" => "system", "content" => "extra", "sections" => OrderedDict("apple" => "new", "zebra" => nothing, "banana" => "last"), "toolsRemoved" => [Dict("name" => "alpha")], "toolsAdded" => [tool("beta")], "timestamp" => 1))
    nothing
end

function response(target)
    occursin(":generateContent", target) && return Dict("candidates" => [Dict("content" => Dict("parts" => [Dict("text" => "done")]), "finishReason" => "STOP")])
    endswith(target, "/responses") && return Dict("id" => "resp", "status" => "completed", "output" => [Dict("type" => "message", "id" => "msg", "role" => "assistant", "status" => "completed", "content" => [Dict("type" => "output_text", "text" => "done", "annotations" => [])])])
    endswith(target, "/messages") && return Dict("content" => [Dict("type" => "text", "text" => "done")], "stop_reason" => "end_turn")
    Dict("choices" => [Dict("message" => Dict("role" => "assistant", "content" => "done"), "finish_reason" => "stop")])
end

systemtext(::Val{:openai}, payload) = payload.messages[1].content
systemtext(::Val{:responses}, payload) = payload.input[1].content
systemtext(::Val{:google}, payload) = payload.systemInstruction.parts[1].text
systemtext(::Val{:anthropic}, payload) = payload.system
pisystem(::Val{:openai}, payload) = payload.messages[1].content
pisystem(::Val{:responses}, payload) = payload.input[1].content
pisystem(::Val{:google}, payload) = payload.config.systemInstruction
pisystem(::Val{:anthropic}, payload) = payload.system[1].text
tooldeclaration(::Val{:openai}, payload) = only(payload.tools).function
tooldeclaration(::Val{:responses}, payload) = only(payload.tools)
tooldeclaration(::Val{:google}, payload) = only(only(payload.tools).functionDeclarations)
tooldeclaration(::Val{:anthropic}, payload) = only(payload.tools)
pitool(::Val{:openai}, payload) = only(payload.tools).function
pitool(::Val{:responses}, payload) = only(payload.tools)
pitool(::Val{:google}, payload) = only(only(payload.config.tools).functionDeclarations)
pitool(::Val{:anthropic}, payload) = only(payload.tools)
schema(::Val{:openai}, tool) = tool.parameters
schema(::Val{:responses}, tool) = tool.parameters
schema(::Val{:google}, tool) = tool.parametersJsonSchema
schema(::Val{:anthropic}, tool) = tool.input_schema

@testset "provider context and declarations against pinned Pi" begin
    if haskey(ENV, "PI_SOURCE")
        source = ENV["PI_SOURCE"]
        @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
        reference = JSON3.read(read(`node --conditions=source --experimental-strip-types $(joinpath(@__DIR__, "context_providers_pi.mjs")) $source`, String))
        requests = Any[]
        server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
            push!(requests, JSON3.read(String(request.body)))
            HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(response(request.target)))
        end
        try
            base = "http://$(HTTP.server_addr(server))"
            providers = (OpenAI(base * "/v1", "fixture", "synthetic-key"), OpenAIResponses(base * "/v1", "fixture", "synthetic-key"), Google(base * "/v1beta", "gemini-3-fixture", "synthetic-key"), Anthropic(base, "claude-fixture", "synthetic-key"; eager_tool_streaming=false))
            names = (:openai, :responses, :google, :anthropic)
            registry = E.Registry()
            E.register!(registry, :fixture, E.Plugin(; hooks=(:context_with_system => patch,)))
            snapshot = E.snapshot(registry)
            for (index, (name, provider)) in enumerate(zip(names, providers))
                agent = Agent(provider, snapshot, Dict{String, Any}[Dict("role" => "system", "content" => "base", "timestamp" => 0)])
                @test respond!(agent, "hello"; on_agent_event=E.listen(snapshot)) == "done"
                native = requests[index]
                pi = reference[name]
                kind = Val(name)
                @test systemtext(kind, native) == pisystem(kind, pi) == "base\n\nextra\n\nnew\n\nlast"
                actual = tooldeclaration(kind, native)
                expected = pitool(kind, pi)
                @test (actual.name, actual.description) == (expected.name, expected.description) == ("beta", "beta")
                @test schema(kind, actual) == schema(kind, expected)
                @test !haskey(agent.messages[1], "sections") && isempty(agent.tools)
                name == :responses && @test haskey(actual, :strict) == haskey(expected, :strict)
            end
        finally
            close(server)
            wait(server)
        end
    end
end

@testset "native context updates against pinned Pi" begin
    if haskey(ENV, "PI_SOURCE")
        source = ENV["PI_SOURCE"]
        reference = JSON3.read(read(`node --conditions=source --experimental-strip-types $(joinpath(@__DIR__, "context_providers_pi.mjs")) $source native`, String))
        requests = Any[]
        server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
            push!(requests, (; payload=JSON3.read(String(request.body)), headers=request.headers))
            HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(response(request.target)))
        end
        try
            base = "http://$(HTTP.server_addr(server))"
            route = J.CatalogRoute("openrouter", J.Models.Registry(J.Models.catalog(), Dict{String, Any}()))
            providers = (OpenAI(base * "/v1", "openai/gpt-5.4", "synthetic-key", Pair{String, String}[], route), OpenAIResponses(base * "/v1", "gpt-5.4", "synthetic-key"), Anthropic(base, "claude-opus-5", "synthetic-key"))
            registry = E.Registry()
            E.register!(registry, :fixture, E.Plugin(; hooks=(:context_with_system => patch,)))
            snapshot = E.snapshot(registry)
            for (index, provider) in enumerate(providers)
                agent = Agent(provider, snapshot, Dict{String, Any}[Dict("role" => "system", "content" => "base", "timestamp" => 0)])
                @test respond!(agent, "hello"; on_agent_event=E.listen(snapshot)) == "done"
                @test !haskey(agent.messages[1], "sections") && isempty(agent.tools)
            end
            openai, responses, anthropic = getproperty.(requests, :payload)
            @test openai.messages == reference.openai.messages
            @test only(openai.tools).function == only(reference.openai.tools).function
            @test responses.input[[1, 2, 4, 5, 6]] == reference.responses.input[[1, 2, 4, 5, 6]]
            @test responses.input[3].content == reference.responses.input[3].content[1].text == "hello"
            @test !haskey(responses, :tools)
            @test anthropic.system == reference.anthropic.system[1].text
            @test anthropic.messages[2].role == "system"
            @test [block.type for block in anthropic.messages[2].content] == [block.type for block in reference.anthropic.messages[2].content]
            @test anthropic.messages[2].content[1].text == reference.anthropic.messages[2].content[1].text
            @test anthropic.messages[2].content[2].tool == reference.anthropic.messages[2].content[2].tool
            @test anthropic.messages[2].content[3].tool.definition.name == reference.anthropic.messages[2].content[3].tool.definition.name == "beta"
            @test anthropic.messages[2].content[3].tool.definition.input_schema == reference.anthropic.messages[2].content[3].tool.definition.input_schema
            @test anthropic.messages[2].content[3].tool.definition.eager_input_streaming == reference.anthropic.messages[2].content[3].tool.definition.eager_input_streaming
            @test [tool.name for tool in anthropic.tools] == [tool.name for tool in reference.anthropic.tools]
            @test any(header -> lowercase(first(header)) == "anthropic-beta" && occursin("inline-tools-2026-09-15", last(header)), requests[3].headers)
        finally
            close(server)
            wait(server)
        end
    end
end

@testset "reasoning model settings select request instruction roles" begin
    requests = Any[]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        push!(requests, JSON3.read(String(request.body)))
        HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(response(request.target)))
    end
    try
        mktempdir() do dir
            path = joinpath(dir, "models.json")
            routerconfig = Dict("models" => [Dict("id" => "custom-reasoner", "reasoning" => true)], "modelOverrides" => Dict("openai/gpt-5.4" => Dict("reasoning" => false)))
            write(path, JSON3.write(Dict("providers" => Dict("openai" => Dict("modelOverrides" => Dict("gpt-5.4" => Dict("reasoning" => false))), "openrouter" => routerconfig))))
            models = J.Models.load(path)
            route = J.CatalogRoute("openai", models)
            registry = E.Registry()
            E.register!(registry, :fixture, E.Plugin(; hooks=(:context_with_system => patch,)))
            snapshot = E.snapshot(registry)
            base = "http://$(HTTP.server_addr(server))/v1"
            for id in ("gpt-5.4", "gpt-5")
                provider = OpenAIResponses(base, id, "synthetic-key", Pair{String, String}[], route)
                agent = Agent(provider, snapshot, Dict{String, Any}[Dict("role" => "system", "content" => "base", "timestamp" => 0)])
                @test respond!(agent, "hello"; on_agent_event=E.listen(snapshot)) == "done"
            end
            router = J.CatalogRoute("openrouter", models)
            provider = OpenAI(base, "openai/gpt-5.4", "synthetic-key", Pair{String, String}[], router)
            agent = Agent(provider, snapshot, Dict{String, Any}[Dict("role" => "system", "content" => "base", "timestamp" => 0)])
            @test respond!(agent, "hello"; on_agent_event=E.listen(snapshot)) == "done"
            for id in ("openai/gpt-5", "qwen/qwen3-32b", "custom-reasoner")
                provider = OpenAI(base, id, "synthetic-key", Pair{String, String}[], router)
                agent = Agent(provider, snapshot, Dict{String, Any}[Dict("role" => "system", "content" => "base", "timestamp" => 0)])
                @test respond!(agent, "hello"; on_agent_event=E.listen(snapshot)) == "done"
            end
            roles = [[String(item.role) for item in request.input] for request in requests[1:2]]
            @test roles == [["developer", "system", "user", "system", "developer", "system"], ["developer", "user"]]
            chatroles = [String(item.role) for item in requests[3].messages]
            @test chatroles == ["system", "user", "system"]
            collapsedroles = [[String(item.role) for item in request.messages] for request in requests[4:6]]
            @test collapsedroles == [["developer", "user"], ["system", "user"], ["system", "user"]]
            if haskey(ENV, "PI_SOURCE")
                source = ENV["PI_SOURCE"]
                @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
                for (index, mode) in enumerate(("reasoning", "reasoning_collapsed"))
                    reference = JSON3.read(read(`node --conditions=source --experimental-strip-types $(joinpath(@__DIR__, "context_providers_pi.mjs")) $source $mode`, String))
                    @test roles[index] == [String(item.role) for item in reference.responses.input]
                end
                reference = JSON3.read(read(`node --conditions=source --experimental-strip-types $(joinpath(@__DIR__, "context_providers_pi.mjs")) $source reasoning_completions`, String))
                @test chatroles == [String(item.role) for item in reference.openai.messages]
                for (index, mode) in enumerate(("reasoning_chat_collapsed", "reasoning_chat_system", "reasoning_chat_custom"))
                    reference = JSON3.read(read(`node --conditions=source --experimental-strip-types $(joinpath(@__DIR__, "context_providers_pi.mjs")) $source $mode`, String))
                    @test collapsedroles[index] == [String(item.role) for item in reference.openai.messages]
                end
            end
        end
    finally
        close(server)
        wait(server)
    end
end


struct ReferencedSchemaTool <: J.Tool end
J.name(::ReferencedSchemaTool) = "schema_ref"
J.description(::ReferencedSchemaTool) = "A tool with referenced input types"
J.schema(::ReferencedSchemaTool) = Dict("type" => "object", "properties" => Dict("selection" => Dict("\$ref" => "#/\$defs/Selection")), "\$defs" => Dict("Selection" => Dict("type" => "string", "enum" => ["a", "b"])), "additionalProperties" => false)

mutable struct ChangingCatalogTool <: J.Tool
    calls::Int
end
J.name(::ChangingCatalogTool) = "changing_schema"
J.description(::ChangingCatalogTool) = "A changing catalog entry"
function J.schema(tool::ChangingCatalogTool)
    tool.calls += 1
    field = tool.calls <= 2 ? "approved" : "changed_after_validation"
    Dict("type" => "object", "properties" => Dict(field => Dict("type" => "string")))
end

end
