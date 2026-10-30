using Test, HTTP, JSON3, JuliaForever
const MCP = JuliaForever.MCP

@testset "Fractional MCP error codes retain the server error" begin
    detail = Dict("code" => -32001.5, "message" => "fractional", "data" => Dict("detail" => "fixture"))
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do req
        req.method == "GET" && return HTTP.Response(405)
        req.method == "DELETE" && return HTTP.Response(204)
        body = JSON3.read(String(req.body), Dict{String, Any})
        haskey(body, "id") || return HTTP.Response(202)
        method, id = body["method"], body["id"]
        if method == "initialize"
            result = Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict(), "serverInfo" => Dict("name" => "fixture", "version" => "1"))
            return HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(Dict("jsonrpc" => "2.0", "id" => id, "result" => result)))
        end
        response = JSON3.write(Dict("jsonrpc" => "2.0", "id" => id, "error" => detail))
        method == "sse" ? HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $response\n\n") : HTTP.Response(200, ["Content-Type" => "application/json"], response)
    end
    url = "http://$(HTTP.server_addr(server))/mcp"
    http = MCP.connect(url; timeout=5)
    script = joinpath(@__DIR__, "mcp_fractional_server.mjs")
    stdio = MCP.connect(`node $script`; timeout=5, grace=0.2)
    try
        for (client, method) in ((http, "json"), (http, "sse"), (stdio, "probe"))
            result = MCP.request(client, method, Dict())
            @test result isa MCP.Failure && result.kind == :rpc
            @test result.message == "fractional"
            @test result.data == detail
        end
        invalid = MCP.rpcerror(Dict("code" => true, "message" => "invalid"))
        @test invalid.kind == :protocol
        if haskey(ENV, "PI_SOURCE")
            @test readchomp(`git -C $(ENV["PI_SOURCE"]) rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
            oracle = joinpath(@__DIR__, "mcp_fractional_pi.mjs")
            for (mode, methods) in (("http", ("json", "sse")), ("stdio", ("probe",)))
                env = Dict("PI_SOURCE" => ENV["PI_SOURCE"], "JF_HTTP_URL" => url, "JF_WIRE_MODE" => mode, "JF_STDIO_SERVER" => script)
                task = @async read(addenv(`node $oracle`, env), String)
                @test timedwait(() -> istaskdone(task), 20) == :ok
                reference = JSON3.read(fetch(task), Dict{String, Any})
                for method in methods
                    @test reference[method] == detail
                end
            end
        end
    finally
        close(http); close(stdio); close(server)
    end
end
