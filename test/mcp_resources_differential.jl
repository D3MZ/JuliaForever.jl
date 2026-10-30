using Test, JSON3, JuliaForever

@testset "MCP resource Pi oracle" begin
    mktempdir() do dir
        marker = joinpath(dir, "marker")
        env = Dict("PI_SOURCE" => ENV["PI_SOURCE"], "JF_JULIA" => first(Base.julia_cmd().exec), "JF_JULIA_PROJECT" => dirname(Base.active_project()), "JF_PROJECT" => dirname(@__DIR__), "JF_MARKER" => marker)
        oracle = JSON3.read(read(addenv(`node $(joinpath(@__DIR__, "mcp_resources_oracle.ts"))`, env), String), Dict{String, Any})
        client = ResourceMCP.connect(resource_server("normal", marker); timeout=10, grace=0.2)
        @test client isa ResourceMCP.Client
        if client isa ResourceMCP.Client
            try
                @test ResourceMCP.resourcepage(client) == oracle["page"]
                @test ResourceMCP.resourcepage(client, "opaque/+=") == oracle["second"]
                @test ResourceMCP.resources(client) == oracle["resources"]
                @test ResourceMCP.templatepage(client) == oracle["templatePage"]
                @test ResourceMCP.templates(client) == oracle["templates"]
                @test ResourceMCP.read(client, "docs://intro") == oracle["text"]
                @test ResourceMCP.read(client, "docs://image") == oracle["blob"]
            finally
                close(client)
            end
        end
    end
end
