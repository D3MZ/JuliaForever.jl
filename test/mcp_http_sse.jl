using Test, HTTP, JSON3, JuliaForever
const MCP = JuliaForever.MCP
seen = Channel{Any}(32)
server = HTTP.serve!("127.0.0.1", 0; listenany=true) do req
    req.method == "DELETE" && (put!(seen, "DELETE"); return HTTP.Response(204))
    body = JSON3.read(String(req.body), Dict{String, Any})
    method = get(body, "method", "response")
    put!(seen, method)
    haskey(body, "id") || return HTTP.Response(202)
    result = method == "initialize" ? Dict("protocolVersion" => "2025-11-25", "capabilities" => Dict("tools" => Dict()), "serverInfo" => Dict("name" => "test", "version" => "1")) : Dict("content" => [Dict("type" => "text", "text" => "streamed")])
    message = JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "result" => result))
    payload = method == "missing" ? ": keepalive\n\n" : ": keepalive\n\nevent: ignored\ndata: not json\n\ndata: $message\n\n"
    HTTP.Response(200, ["Content-Type" => "text/event-stream; charset=utf-8", "Mcp-Session-Id" => "sse-session"], payload)
end
try
    client = MCP.connect("http://$(HTTP.server_addr(server))/mcp"; timeout=2)
    @test client isa MCP.Client
    if client isa MCP.Client
        @test MCP.call(client, "echo", Dict())["content"][1]["text"] == "streamed"
        @test MCP.request(client, "missing", Dict()).kind == :protocol
        close(client)
        close(client)
        @test [take!(seen) for _ in 1:5] == ["initialize", "notifications/initialized", "tools/call", "missing", "DELETE"]
    end
finally
    close(server)
end

started = Channel{String}(4)
release = Channel{Nothing}(4)
server = HTTP.listen!("127.0.0.1", 0; listenany=true) do io
    request = HTTP.startread(io)
    if request.method == "DELETE"
        HTTP.setstatus(io, 204)
        HTTP.startwrite(io)
        return
    end
    body = JSON3.read(String(read(io)), Dict{String, Any})
    method = get(body, "method", "")
    if method == "initialize"
        result = Dict("protocolVersion" => "2025-11-25", "capabilities" => Dict("tools" => Dict()), "serverInfo" => Dict("name" => "test", "version" => "1"))
        HTTP.setheader(io, "Content-Type" => "application/json")
        HTTP.setheader(io, "Mcp-Session-Id" => "session")
        HTTP.startwrite(io)
        write(io, JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "result" => result)))
    elseif haskey(body, "id")
        HTTP.setheader(io, "Content-Type" => "text/event-stream")
        HTTP.startwrite(io)
        write(io, ": waiting\n\n")
        flush(io)
        put!(started, method)
        take!(release)
    else
        HTTP.setstatus(io, 202)
        HTTP.startwrite(io)
    end
end
try
    client = MCP.connect("http://$(HTTP.server_addr(server))/mcp"; timeout=2)
    task = @async MCP.request(client, "timeout", Dict(); timeout=0.2)
    @test take!(started) == "timeout"
    @test fetch(task).kind == :timeout
    @test timedwait(() -> isempty(client.process.requests), 2) == :ok
    put!(release, nothing)
    task = @async MCP.request(client, "close", Dict())
    @test take!(started) == "close"
    close(client)
    @test fetch(task).kind == :closed
    @test timedwait(() -> isempty(client.process.requests), 2) == :ok
    put!(release, nothing)
finally
    close(server)
end
