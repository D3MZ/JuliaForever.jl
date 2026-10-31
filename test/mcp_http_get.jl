using Test, HTTP, JSON3, JuliaForever
const MCP = JuliaForever.MCP
seen = Channel{Any}(20)
release = Channel{Nothing}(1)
server = HTTP.listen!("127.0.0.1", 0; listenany=true) do io
    request = HTTP.startread(io)
    headers = Dict(lowercase(k) => v for (k, v) in request.headers)
    if request.method == "GET"
        put!(seen, ("GET", headers, nothing))
        HTTP.setheader(io, "Content-Type" => "text/event-stream")
        HTTP.startwrite(io)
        for message in (Dict("jsonrpc" => "2.0", "id" => "ping-id", "method" => "ping"), Dict("jsonrpc" => "2.0", "id" => "roots-id", "method" => "roots/list"), Dict("jsonrpc" => "2.0", "id" => "missing-id", "method" => "unknown"))
            write(io, "data: $(JSON3.write(message))\n\n")
            flush(io)
        end
        take!(release)
    elseif request.method == "DELETE"
        put!(seen, ("DELETE", headers, nothing))
        HTTP.setstatus(io, 204)
        HTTP.startwrite(io)
    else
        body = JSON3.read(String(read(io)), Dict{String, Any})
        put!(seen, ("POST", headers, body))
        if get(body, "method", "") == "initialize"
            result = Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict(), "serverInfo" => Dict("name" => "test", "version" => "1"))
            HTTP.setheader(io, "Content-Type" => "application/json")
            HTTP.setheader(io, "Mcp-Session-Id" => "session-1")
            HTTP.startwrite(io)
            write(io, JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "result" => result)))
        else
            HTTP.setstatus(io, 202)
            HTTP.startwrite(io)
        end
    end
end
@testset "HTTP server-initiated stream" begin
    client = MCP.connect("http://$(HTTP.server_addr(server))/mcp"; timeout=2, roots=[(; uri="file:///workspace")], headers=["Authorization" => "Bearer secret"])
    try
        @test client isa MCP.Client
        @test timedwait(() -> length(seen.data) >= 6, 5) == :ok
        items = [take!(seen) for _ in 1:6]
        getitem = only(filter(item -> item[1] == "GET", items))
        @test getitem[2]["mcp-session-id"] == "session-1"
        @test getitem[2]["mcp-protocol-version"] == "2025-06-18"
        @test getitem[2]["authorization"] == "Bearer secret"
        responses = Dict(item[3]["id"] => item[3] for item in items if item[1] == "POST" && haskey(item[3], "id") && !haskey(item[3], "method"))
        @test responses["ping-id"]["result"] == Dict()
        @test responses["roots-id"]["result"]["roots"][1]["uri"] == "file:///workspace"
        @test responses["missing-id"]["error"]["code"] == -32601
        close(client)
        @test take!(seen)[1] == "DELETE"
        put!(release, nothing)
        if haskey(ENV, "PI_SOURCE")
            @test readchomp(`git -C $(ENV["PI_SOURCE"]) rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
            env = Dict("PI_SOURCE" => ENV["PI_SOURCE"], "JF_HTTP_URL" => "http://$(HTTP.server_addr(server))/mcp")
            oracle = @async read(addenv(`node $(joinpath(@__DIR__, "mcp_http_get_oracle.mjs"))`, env), String)
            @test timedwait(() -> istaskdone(oracle), 15) == :ok
            fetch(oracle)
            pi = [take!(seen) for _ in 1:7]
            piget = only(filter(item -> item[1] == "GET", pi))
            @test [piget[2][key] for key in ("mcp-session-id", "mcp-protocol-version", "authorization")] == [getitem[2][key] for key in ("mcp-session-id", "mcp-protocol-version", "authorization")]
            piresponses = Dict(item[3]["id"] => item[3] for item in pi if item[1] == "POST" && haskey(item[3], "id") && !haskey(item[3], "method"))
            @test piresponses["ping-id"]["result"] == responses["ping-id"]["result"]
            @test piresponses["roots-id"]["result"] == responses["roots-id"]["result"]
            @test piresponses["missing-id"]["error"]["code"] == responses["missing-id"]["error"]["code"]
            @test pi[end][1] == "DELETE"
        end
    finally
        close(client)
        isready(release) || put!(release, nothing)
        close(server)
    end
end

messages = Channel{Any}(10)
sent = Channel{Nothing}(1)
started = Channel{Nothing}(1)
server = HTTP.listen!("127.0.0.1", 0; listenany=true) do io
    request = HTTP.startread(io)
    if request.method == "GET"
        HTTP.setheader(io, "Content-Type" => "text/event-stream")
        HTTP.startwrite(io)
        put!(started, nothing)
        try
            write(io, "event: ignored\ndata: not json\n\ndata: malformed\n\n")
            flush(io)
            for message in messages
                write(io, "data: $(JSON3.write(message))\n\n")
                flush(io)
                put!(sent, nothing)
            end
        catch
        end
    elseif request.method == "DELETE"
        HTTP.setstatus(io, 204)
        HTTP.startwrite(io)
    else
        body = JSON3.read(String(read(io)), Dict{String, Any})
        method = get(body, "method", "")
        if method == "initialize"
            HTTP.setheader(io, "Content-Type" => "application/json")
            HTTP.setheader(io, "Mcp-Session-Id" => "progress-session")
            HTTP.startwrite(io)
            result = Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict(), "serverInfo" => Dict("name" => "test", "version" => "1"))
            write(io, JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "result" => result)))
        elseif method == "probe"
            put!(messages, Dict("jsonrpc" => "2.0", "method" => "notifications/progress", "params" => Dict("progressToken" => body["params"]["_meta"]["progressToken"], "progress" => 1)))
            take!(sent)
            sleep(0.2)
            HTTP.setheader(io, "Content-Type" => "application/json")
            HTTP.startwrite(io)
            write(io, JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "result" => Dict("ok" => true))))
        else
            HTTP.setstatus(io, 202)
            HTTP.startwrite(io)
        end
    end
end
