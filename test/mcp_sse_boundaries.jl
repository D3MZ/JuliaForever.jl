using Test, HTTP, JSON3, JuliaForever
const MCP = JuliaForever.MCP
takebefore(channel) = timedwait(() -> isready(channel), 10) == :ok ? take!(channel) : error("timed out waiting for MCP fixture")

@testset "Concurrent response streams retain request ownership" begin
    firstid = Channel{Int}(2)
    release = Channel{Nothing}(2)
    server = HTTP.listen!("127.0.0.1", 0; listenany=true) do io
        req = HTTP.startread(io)
        if req.method == "GET"
            HTTP.setstatus(io, 405); HTTP.startwrite(io)
        elseif req.method == "DELETE"
            HTTP.setstatus(io, 204); HTTP.startwrite(io)
        elseif endswith(req.target, "/release")
            put!(release, nothing)
            HTTP.setstatus(io, 204); HTTP.startwrite(io)
        else
            body = JSON3.read(read(io), Dict{String, Any})
            method = get(body, "method", "")
            if method == "initialize"
                result = Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict(), "serverInfo" => Dict("name" => "fixture", "version" => "1"))
                HTTP.setheader(io, "Content-Type" => "application/json"); HTTP.startwrite(io)
                write(io, JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "result" => result)))
            elseif method == "first"
                HTTP.setheader(io, "Content-Type" => "text/event-stream"); HTTP.startwrite(io)
                write(io, ": waiting\n\n"); flush(io)
                put!(firstid, body["id"])
                take!(release)
            elseif method == "second"
                other = take!(firstid)
                response(id, value) = "data: $(JSON3.write(Dict("jsonrpc" => "2.0", "id" => id, "result" => value)))\n\n"
                invalid = "data: $(JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "error" => nothing)))\n\n"
                HTTP.setheader(io, "Content-Type" => "text/event-stream"); HTTP.startwrite(io)
                for part in ("data: {bad\n\n", response(other, "first"), invalid, response(body["id"], "second"))
                    write(io, part); flush(io)
                end
            else
                HTTP.setstatus(io, 202); HTTP.startwrite(io)
            end
        end
    end
    url = "http://$(HTTP.server_addr(server))/mcp"
    client = MCP.connect(url; timeout=10)
    try
        first = @async MCP.request(client, "first", Dict())
        @test timedwait(() -> isready(firstid), 5) == :ok
        second = @async MCP.request(client, "second", Dict())
        @test fetch(first) == "first"
        @test fetch(second) == "second"
        @test isempty(client.pending)
        put!(release, nothing)
        if haskey(ENV, "PI_SOURCE")
            env = Dict("PI_SOURCE" => ENV["PI_SOURCE"], "JF_HTTP_URL" => url)
            oracle = @async read(addenv(`node $(joinpath(@__DIR__, "mcp_sse_concurrent_pi.mjs"))`, env), String)
            @test timedwait(() -> istaskdone(oracle), 15) == :ok
            result = JSON3.read(fetch(oracle), Dict{String, Any})
            @test result["results"] == ["first", "second"]
            @test result["errors"] == 2
        end
    finally
        put!(release, nothing)
        close(client); close(server)
    end
end

@testset "Malformed response events retain the reconnect cursor" begin
    cursors = Channel{Tuple{String, String}}(8)
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do req
        if req.method == "GET"
            cursor = HTTP.header(req, "Last-Event-ID", "")
            isempty(cursor) && return HTTP.Response(405)
            put!(cursors, (cursor, HTTP.header(req, "Authorization", "")))
            return HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: {bad\n\ndata: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"ok\":true}}\n\n")
        end
        req.method == "DELETE" && return HTTP.Response(204)
        body = JSON3.read(String(req.body), Dict{String, Any})
        haskey(body, "id") || return HTTP.Response(202)
        if body["method"] == "initialize"
            result = Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict(), "serverInfo" => Dict("name" => "fixture", "version" => "1"))
            return HTTP.Response(200, ["Content-Type" => "application/json", "Mcp-Session-Id" => "fixture"], JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "result" => result)))
        end
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], "id: cursor\nretry: 0\ndata: {bad\n\n")
    end
    url = "http://$(HTTP.server_addr(server))/mcp"
    client = MCP.connect(url; timeout=10, headers=["Authorization" => "Bearer secret"])
    try
        @test MCP.request(client, "probe", Dict()) == Dict("ok" => true)
        @test timedwait(() -> isready(cursors), 5) == :ok
        isready(cursors) && @test take!(cursors) == ("cursor", "Bearer secret")
        if haskey(ENV, "PI_SOURCE")
            env = Dict("PI_SOURCE" => ENV["PI_SOURCE"], "JF_HTTP_URL" => url)
            oracle = @async read(addenv(`node $(joinpath(@__DIR__, "mcp_reconnect_oracle.mjs"))`, env), String)
            @test timedwait(() -> istaskdone(oracle), 10) == :ok
            @test JSON3.read(fetch(oracle), Dict{String, Any}) == Dict("ok" => true)
            @test timedwait(() -> isready(cursors), 5) == :ok
            isready(cursors) && @test take!(cursors) == ("cursor", "Bearer secret")
        end
    finally
        close(client); close(server)
    end
end

@testset "Oversized response events stop before a later response" begin
    resumed = Channel{String}(2)
    oversized = repeat("x", 16 * 1024 * 1024 + 1)
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do req
        if req.method == "GET"
            cursor = HTTP.header(req, "Last-Event-ID", "")
            isempty(cursor) || put!(resumed, cursor)
            return HTTP.Response(405)
        end
        req.method == "DELETE" && return HTTP.Response(204)
        body = JSON3.read(String(req.body), Dict{String, Any})
        haskey(body, "id") || return HTTP.Response(202)
        if body["method"] == "initialize"
            result = Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict(), "serverInfo" => Dict("name" => "fixture", "version" => "1"))
            return HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "result" => result)))
        end
        good = JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "result" => "must not deliver"))
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], "id: cursor\nretry: 0\ndata: $oversized\n\ndata: $good\n\n")
    end
    url = "http://$(HTTP.server_addr(server))/mcp"
    client = MCP.connect(url; timeout=30)
    try
        result = MCP.request(client, "oversize", Dict())
        @test result isa MCP.Failure && result.kind == :protocol
        @test !isready(resumed)
        if haskey(ENV, "PI_SOURCE")
            env = Dict("PI_SOURCE" => ENV["PI_SOURCE"], "JF_HTTP_URL" => url)
            oracle = @async read(addenv(`node $(joinpath(@__DIR__, "mcp_post_sse_pi.mjs")) oversize`, env), String)
            @test timedwait(() -> istaskdone(oracle), 20) == :ok
            result = JSON3.read(fetch(oracle), Dict{String, Any})["oversize"]
            @test result["error"]["code"] == -32603
            @test occursin("exceeds", result["error"]["message"])
            @test !isready(resumed)
        end
    finally
        close(client); close(server)
    end
end
