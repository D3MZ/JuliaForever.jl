using Test, JSON3, JuliaForever

@testset "MCP B1 oracle" begin
    @test readchomp(`git -C $(ENV["PI_SOURCE"]) rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    mktempdir() do dir
        marker = joinpath(dir, "marker")
        env = Dict("PI_SOURCE" => ENV["PI_SOURCE"], "JF_JULIA" => first(Base.julia_cmd().exec), "JF_JULIA_PROJECT" => dirname(Base.active_project()), "JF_PROJECT" => dirname(@__DIR__), "JF_MARKER" => marker)
        oracle = JSON3.read(read(addenv(`node $(joinpath(@__DIR__, "mcp_oracle.ts"))`, env), String), Dict{String, Any})
        client = JuliaForever.MCP.connect(mcpserver("normal", marker); timeout=10, grace=0.2)
        @test client isa JuliaForever.MCP.Client
        if client isa JuliaForever.MCP.Client
            try
                remote = JuliaForever.MCP.tools(client)
                @test client.server["protocolVersion"] == oracle["version"]
                @test [(tool.remote, tool.doc, tool.parameters) for tool in remote] == [(item["name"], get(item, "description", item["name"]), item["inputSchema"]) for item in oracle["tools"]]
                @test JuliaForever.MCP.call(client, "alpha", Dict("value" => 7)) == oracle["echo"]
                @test JuliaForever.MCP.call(client, "tool_error", Dict()) == oracle["toolError"]
                @test JuliaForever.MCP.call(client, "mixed", Dict()) == oracle["mixed"]
                for name in ("image_direct", "image_embedded", "image_mixed", "image_error", "image_multiple")
                    reference = oracle["images"][name]
                    @test JuliaForever.MCP.call(client, name, Dict()) == reference["raw"]
                    tool = JuliaForever.MCP.RemoteTool(client, name, name, "", Dict("type" => "object"))
                    actual = execute(tool, Dict())
                    images = filter(block -> block["type"] == "image", reference["content"])
                    if name == "image_multiple"
                        @test length(images) == 2 && actual.iserror && actual.image === nothing
                    else
                        @test length(images) == 1
                        @test actual.image.mime == only(images)["mimeType"]
                        @test actual.image.data == only(images)["data"]
                        @test actual.iserror == reference["raw"]["isError"]
                    end
                end
                failure = JuliaForever.MCP.call(client, "protocol_error", Dict())
                @test failure isa JuliaForever.MCP.Failure && failure.data["code"] == oracle["code"]
            finally
                close(client)
            end
        end
    end
end
