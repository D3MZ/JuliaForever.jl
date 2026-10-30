using Test, JuliaForever, JSON3
const MCP = JuliaForever.MCP

@testset "MCP stdio message size and recovery" begin
    limit = 16 * 1024 * 1024
    script = joinpath(@__DIR__, "mcp_stdio_limit_server.mjs")
    client = MCP.connect(`node $script`; timeout=30, grace=0.2)
    try
        value = MCP.request(client, "at_limit", Dict())
        accepted = value isa String && ncodeunits(value) == limit - ncodeunits(JSON3.write(Dict("jsonrpc" => "2.0", "id" => 2, "result" => ""))) && startswith(value, "é")
        @test accepted
        large = MCP.request(client, "over_limit", Dict())
        recovered = large isa AbstractDict && large == Dict("scenario" => "over_limit")
        @test recovered
        @test MCP.request(client, "reset_tail", Dict(); timeout=15) == Dict("scenario" => "reset_tail")
        @test MCP.request(client, "fragmented", Dict()) == Dict("scenario" => "fragmented")
        @test MCP.request(client, "valid", Dict()) == Dict("scenario" => "valid")
        if haskey(ENV, "PI_SOURCE")
            @test readchomp(`git -C $(ENV["PI_SOURCE"]) rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
            env = Dict("PI_SOURCE" => ENV["PI_SOURCE"], "JF_STDIO_SERVER" => script)
            oracle = joinpath(@__DIR__, "mcp_stdio_limit_pi.mjs")
            task = @async read(addenv(`node $oracle at_limit over_limit reset_tail fragmented valid`, env), String)
            @test timedwait(() -> istaskdone(task), 45) == :ok
            pi = JSON3.read(fetch(task), Dict{String, Any})
            @test pi["at_limit"]["length"] == limit - ncodeunits(JSON3.write(Dict("jsonrpc" => "2.0", "id" => 1, "result" => ""))) - 1
            @test pi["at_limit"]["errors"] == 0
            for method in ("over_limit", "reset_tail", "fragmented", "valid")
                @test pi[method]["result"] == Dict("scenario" => method)
            end
            @test pi["over_limit"]["errors"] >= 1
            @test pi["reset_tail"]["errors"] >= 1
            @test pi["valid"]["errors"] == 0
        end
    finally
        close(client)
    end
end
