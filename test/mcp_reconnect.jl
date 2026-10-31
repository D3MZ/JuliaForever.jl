using Test, HTTP, JSON3, JuliaForever
const MCP = JuliaForever.MCP

@testset "SSE reconnection" begin
    gets = Channel{Tuple{String,String}}(20)
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do req
        headers = Dict(lowercase(k) => v for (k,v) in req.headers)
        if req.method == "GET"
            id = get(headers, "last-event-id", "")
            put!(gets, (id, get(headers, "authorization", "")))
            id == "response-id" && return HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"ok\":true}}\n\n")
            id == "get-id" && return HTTP.Response(405)
            return HTTP.Response(200, ["Content-Type" => "text/event-stream"], "id: get-id\nretry: 10\n\n")
        end
        req.method == "DELETE" && return HTTP.Response(204)
        body = JSON3.read(String(req.body), Dict{String,Any})
        haskey(body, "id") || return HTTP.Response(202)
        if body["method"] == "initialize"
            result = Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict(), "serverInfo" => Dict("name" => "test", "version" => "1"))
            return HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "result" => result)))
        end
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], "id: response-id\nretry: 10\n\n")
    end
    client = MCP.connect("http://$(HTTP.server_addr(server))/mcp"; timeout=10, headers=["Authorization" => "Bearer secret"])
    try
        @test MCP.request(client, "probe", Dict()) == Dict("ok" => true)
        @test timedwait(() -> length(gets.data) >= 3, 2) == :ok
        found = [take!(gets) for _ in 1:length(gets.data)]
        @test Set(first.(found)) == Set(["", "get-id", "response-id"])
        @test all(last(item) == "Bearer secret" for item in found)
        if haskey(ENV, "PI_SOURCE")
            @test readchomp(`git -C $(ENV["PI_SOURCE"]) rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
            env = Dict("PI_SOURCE" => ENV["PI_SOURCE"], "JF_HTTP_URL" => "http://$(HTTP.server_addr(server))/mcp")
            oracle = @async read(addenv(`node $(joinpath(@__DIR__, "mcp_reconnect_oracle.mjs"))`, env), String)
            @test timedwait(() -> istaskdone(oracle), 5) == :ok
            @test JSON3.read(fetch(oracle), Dict{String,Any}) == Dict("ok" => true)
            pi = [take!(gets) for _ in 1:length(gets.data)]
            @test Set(first.(pi)) == Set(first.(found))
            @test all(last(item) == "Bearer secret" for item in pi)
        end
    finally
        close(client); close(server)
    end
end

@testset "Cursor fields match pinned Pi" begin
    transport = MCP.HttpTransport("", Pair{String,String}[], "", "", Dict{Int,HTTP.RequestContext}(), HTTP.RequestContext(), Dict{HTTP.RequestContext,Task}(), Set{Task}())
    client = MCP.Client(transport, ReentrantLock(), ReentrantLock(), Dict{Int,MCP.Pending}(), 0, MCP.Open(), nothing, 1.0, 0.0, false, Base.Event(), nothing, MCP.NoRoots())
    cases = ["id: first\n\nid: second\nretry: 25\n\n", "id: keep\nid: bad\0id\nretry: -2\nretry: 17\n", "id: reset\n\nid:\nretry: 0\n\n"]
    for input in cases
        cursor = MCP.StreamCursor()
        MCP.sseread!(client, IOBuffer(input), MCP.ServerStream(), cursor)
        if haskey(ENV, "PI_SOURCE")
            # NUL cannot be passed through an environment variable.
            oracle = read(pipeline(addenv(`node $(joinpath(@__DIR__, "mcp_cursor_oracle.mjs"))`, "PI_SOURCE" => ENV["PI_SOURCE"]); stdin=IOBuffer(input)), String)
            expected = JSON3.read(oracle, Dict{String,Any})
            @test cursor.id == expected["id"]
            @test cursor.retry == expected["retry"]
        end
    end
end
