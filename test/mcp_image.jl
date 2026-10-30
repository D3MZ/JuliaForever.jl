using Test, JuliaForever, HTTP, JSON3, Base64

mutable struct MCPImageProvider
    requests::Vector{Any}
end

function JuliaForever.complete(provider::MCPImageProvider, messages, tools)
    push!(provider.requests, deepcopy(messages))
    if length(provider.requests) == 1
        call = Dict("id" => "mcp-image", "type" => "function", "function" => Dict("name" => "mcp_image_mixed", "arguments" => "{}"))
        return Dict("role" => "assistant", "content" => nothing, "tool_calls" => [call])
    end
    Dict("role" => "assistant", "content" => "done")
end

@testset "MCP image adaptation" begin
    mktempdir() do dir
        client = MCP.connect(mcpserver("normal", joinpath(dir, "marker")); timeout=30, grace=0.2)
        @test client isa MCP.Client
        if client isa MCP.Client
            try
                remote(name) = MCP.RemoteTool(client, name, "mcp_" * name, "", Dict("type" => "object"))
                png = base64encode(read(joinpath(@__DIR__, "fixtures", "pixel.png")))
                jpeg = base64encode(read(joinpath(@__DIR__, "fixtures", "pixel.jpg")))
                direct = execute(remote("image_direct"), Dict())
                @test !direct.iserror && direct.text == "[MCP image attached]"
                @test isequal(direct.image, Image("image/png", png))
                embedded = execute(remote("image_embedded"), Dict())
                @test !embedded.iserror && embedded.text == "[MCP image attached]"
                @test isequal(embedded.image, Image("image/jpeg", jpeg))
                failed = execute(remote("image_error"), Dict())
                @test failed.iserror && isequal(failed.image, direct.image)
                mixed = execute(remote("image_mixed"), Dict())
                @test !mixed.iserror && isequal(mixed.image, direct.image)
                @test startswith(mixed.text, "before\n[MCP image attached]\nafter\n")
                @test occursin("file:///item", mixed.text) && occursin("\"value\":3", mixed.text)
                raw = MCP.call(client, "image_mixed", Dict())
                @test raw["content"][2]["data"] == png
                @test raw["content"][2]["_meta"]["fixture"]
                @test raw["structuredContent"]["value"] == 3
                multiple = execute(remote("image_multiple"), Dict())
                @test multiple.iserror && multiple.image === nothing
                @test occursin("multiple", lowercase(multiple.text))
                @test all(text -> occursin(text, multiple.text), ("before", "between", "after"))
                @test !occursin(png, multiple.text) && !occursin(jpeg, multiple.text)
                boundary = execute(remote("image_boundary"), Dict())
                @test !boundary.iserror && length(base64decode(boundary.image.data)) == 10 * 1024 * 1024
                for (name, reason) in (("image_unsupported", "image/gif"), ("image_embedded_unsupported", "image/svg+xml"), ("image_embedded_missing", "malformed"), ("image_missing", "malformed"), ("image_invalid_base64", "base64"), ("image_mismatch", "mismatch"), ("image_animated", "animated"), ("image_oversized", "10 MiB"), ("image_overlong", "10 MiB"))
                    result = execute(remote(name), Dict())
                    @test result.iserror && result.image === nothing
                    @test occursin(lowercase(reason), lowercase(result.text))
                end

                provider = MCPImageProvider([])
                history = JuliaForever.History.Memory()
                tool = remote("image_mixed")
                agent = Agent(provider, [tool]; history)
                @test respond!(agent, "fetch image") == "done"
                saved = only(filter(message -> message isa JuliaForever.Conversation.ToolMessage, agent.state.messages))
                @test saved.content == mixed.text && isequal(saved.image, direct.image)
                @test provider.requests[2][end]["image"] == Dict("mime" => "image/png", "data" => png)
                restored = Agent(provider, [tool]; history)
                @test isequal(only(filter(message -> message isa JuliaForever.Conversation.ToolMessage, restored.state.messages)).image, direct.image)

                for api in (:chat, :responses)
                    model = api == :chat ? OpenAI("http://unused", "synthetic", "key") : OpenAIResponses("http://unused", "synthetic", "key")
                    payload = JSON3.read(JuliaForever.payload(model, provider.requests[2], Dict(), Dict()))
                    url = "data:image/png;base64," * png
                    if api == :chat
                        result = only(filter(item -> item.role == "tool", payload.messages))
                        @test result.content == mixed.text
                        @test last(payload.messages).content[2].image_url.url == url
                    else
                        result = only(filter(item -> get(item, :type, "") == "function_call_output", payload.input))
                        @test result.output[1].text == mixed.text
                        @test result.output[2].image_url == url
                    end
                    requests = Any[]
                    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
                        push!(requests, JSON3.read(String(request.body)))
                        if api == :chat
                            call = Dict("id" => "mcp-image", "type" => "function", "function" => Dict("name" => "mcp_image_mixed", "arguments" => "{}"))
                            message = length(requests) == 1 ? Dict("role" => "assistant", "content" => nothing, "tool_calls" => [call]) : Dict("role" => "assistant", "content" => "done")
                            HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write((; choices=[(; message, finish_reason=length(requests) == 1 ? "tool_calls" : "stop")])))
                        else
                            output = length(requests) == 1 ? [Dict("type" => "function_call", "id" => "fc1", "call_id" => "mcp-image", "name" => "mcp_image_mixed", "arguments" => "{}", "status" => "completed")] : [Dict("type" => "message", "role" => "assistant", "content" => [Dict("type" => "output_text", "text" => "done")])]
                            HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(Dict("status" => "completed", "output" => output)))
                        end
                    end
                    try
                        base = "http://$(HTTP.server_addr(server))/v1"
                        model = api == :chat ? OpenAI(base, "synthetic", "key") : OpenAIResponses(base, "synthetic", "key")
                        @test respond!(Agent(model, [tool]), "fetch image") == "done"
                        if api == :chat
                            result = only(filter(item -> item.role == "tool", requests[2].messages))
                            @test result.content == mixed.text
                            @test last(requests[2].messages).content[2].image_url.url == url
                        else
                            result = only(filter(item -> get(item, :type, "") == "function_call_output", requests[2].input))
                            @test result.output[1].text == mixed.text
                            @test result.output[2].image_url == url
                        end
                    finally
                        close(server)
                    end
                end
            finally
                close(client)
            end
        end
    end
end
