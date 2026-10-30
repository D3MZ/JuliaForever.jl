using Test, JSON3, JuliaForever

const RootsMCP = JuliaForever.MCP

@testset "MCP roots against Pi" begin
    @test readchomp(`git -C $(ENV["PI_SOURCE"]) rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    fixture = joinpath(@__DIR__, "mcp_roots_server.mjs")
    env = Dict("PI_SOURCE" => ENV["PI_SOURCE"], "JF_PROJECT" => dirname(@__DIR__))
    check(client) = RootsMCP.request(client, "fixture/check", Dict(); timeout=5)
    connect(target::Cmd; kwargs...) = RootsMCP.connect(target; timeout=5, grace=0.2, kwargs...)
    connect(target::AbstractString; kwargs...) = RootsMCP.connect(target; timeout=5, kwargs...)
    function exercise(target, oracle)
        function once(; kwargs...)
            client = connect(target; kwargs...)
            try
                check(client)
            finally
                close(client)
            end
        end
        @test once() == oracle["absent"]
        @test once(; roots=NamedTuple[]) == oracle["empty"]
        @test once(; roots=[(; uri="file:///workspace", name="workspace"), (; uri="file:///other")]) == oracle["fixed"]

        current = Ref([(; uri="file:///first", name="first")])
        reference = Ref{RootsMCP.Client}()
        roots = () -> begin
            pulse = RootsMCP.request(reference[], "fixture/pulse", Dict(); timeout=3)
            pulse["pulse"] || error("missing pulse")
            current[]
        end
        client = connect(target; roots)
        reference[] = client
        try
            @test check(client) == oracle["first"]
            current[] = [(; uri="file:///second", name="second")]
            @test check(client) == oracle["second"]
        finally
            close(client)
        end
        @test once(; roots=() -> error("root lookup failed")) == oracle["failed"]
    end
    function compare(target, env)
        oracle = JSON3.read(read(addenv(`node $(joinpath(@__DIR__, "mcp_roots_oracle.mjs"))`, env), String), Dict{String, Any})
        exercise(target, oracle)
    end
    compare(`node $fixture`, env)
    server = open(`node $fixture --http`, "r+")
    try
        url = "http://127.0.0.1:$(readline(server))/mcp"
        compare(url, merge(env, Dict("JF_ROOTS_HTTP_URL" => url)))
    finally
        kill(server)
        wait(server)
        close(server)
    end
end
