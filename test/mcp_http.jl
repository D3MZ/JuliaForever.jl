using Test, HTTP, JSON3, Base64, JuliaForever
const MCP = JuliaForever.MCP
requests = Channel{Any}(32)
server = HTTP.serve!("127.0.0.1", 0) do req
    req.method == "DELETE" && (put!(requests, (req.method, Dict(lowercase(k) => v for (k, v) in req.headers), Dict())); return HTTP.Response(204))
    try
    body = isempty(req.body) ? Dict() : JSON3.read(String(req.body), Dict{String, Any})
    put!(requests, (req.method, Dict(lowercase(k) => v for (k, v) in req.headers), body))
    method = get(body, "method", "")
    !haskey(body, "id") && return HTTP.Response(202)
    method == "bad/status" && return HTTP.Response(401)
    method == "bad/stream" && return HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: {}\n\n")
    result = method == "initialize" ? Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict("tools" => Dict(), "resources" => Dict()), "serverInfo" => Dict("name" => "test", "version" => "1")) : method == "tools/list" ? Dict("tools" => [Dict("name" => "echo", "inputSchema" => Dict("type" => "object"))]) : method == "tools/call" ? Dict("content" => [Dict("type" => "text", "text" => "ok"), Dict("type" => "resource", "resource" => Dict("uri" => "test://pixel", "mimeType" => "image/png", "blob" => base64encode(read(joinpath(@__DIR__, "fixtures", "pixel.png")))) )]) : method == "resources/list" ? Dict("resources" => [Dict("uri" => "test://one", "name" => "one")]) : Dict("contents" => [Dict("uri" => "test://one", "text" => "resource")])
    HTTP.Response(200, ["Content-Type" => "application/json", "Mcp-Session-Id" => "session-1"], JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "result" => result)))
    catch e
        showerror(stderr, e, catch_backtrace()); println(stderr)
        HTTP.Response(500)
    end
end
try
    url = "http://127.0.0.1:$(HTTP.port(server))/mcp"
    client = MCP.connect(url; timeout=30)
    @test client isa MCP.Client
    late = typemax(Int)
    @test MCP.received(client, Dict("jsonrpc" => "2.0", "id" => late, "result" => Dict()))
    @test MCP.httpfailure!(client, Dict("id" => late), MCP.Failure(:transport, "late"))
    @test MCP.cancelhttp!(client.process, client, late) === true
    @test length(MCP.tools(client)) == 1
    @test MCP.call(client, "echo", Dict())["content"][1]["text"] == "ok"
    adapted = JuliaForever.execute(only(MCP.tools(client)), (;))
    @test adapted.image isa JuliaForever.Image
    @test occursin("[MCP image attached]", adapted.text)
    @test only(MCP.resources(client))["uri"] == "test://one"
    @test read(client, "test://one")["contents"][1]["text"] == "resource"
    @test MCP.request(client, "bad/status", Dict()).kind == :http
    @test MCP.request(client, "bad/stream", Dict()).kind == :protocol
    close(client)
    seen = [take!(requests) for _ in 1:11]
    @test seen[2][2]["mcp-session-id"] == "session-1"
    @test seen[2][2]["mcp-protocol-version"] == "2025-06-18"
    @test seen[end][1] == "DELETE"
finally
    close(server)
end
