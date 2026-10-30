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

@testset "Retries and close during backoff" begin
    seen = Channel{Tuple{String,Float64}}(20)
    count = Ref(0)
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do req
        if req.method == "GET"
            count[] += 1
            id = HTTP.header(req, "Last-Event-ID", "")
            put!(seen, (id, time()))
            count[] == 1 && return HTTP.Response(200, ["Content-Type" => "text/event-stream"], "id: cursor\nretry: 30\n\n")
            count[] == 2 && return HTTP.Response(503)
            count[] == 3 && return HTTP.Response(429)
            count[] == 4 && return HTTP.Response(408)
            return HTTP.Response(200, ["Content-Type" => "text/event-stream"], "id: cursor2\nretry: 10000\n\n")
        end
        req.method == "DELETE" && return HTTP.Response(204)
        body = JSON3.read(String(req.body), Dict{String,Any})
        haskey(body, "id") || return HTTP.Response(202)
        result = Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict(), "serverInfo" => Dict("name" => "test", "version" => "1"))
        HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "result" => result)))
    end
    client = MCP.connect("http://$(HTTP.server_addr(server))/mcp"; timeout=10)
    try
        @test timedwait(() -> length(seen.data) >= 5, 3) == :ok
        events = [take!(seen) for _ in 1:5]
        @test first.(events) == ["", "cursor", "cursor", "cursor", "cursor"]
        @test all(events[i+1][2] - events[i][2] >= 0.02 for i in 1:4)
        start = time()
        close(client)
        @test time() - start < 1.0
        @test istaskdone(client.reader)
        @test !isready(seen)
    finally
        close(client); close(server)
    end
end

@testset "Reconnect does not follow redirects" begin
    seen = Channel{String}(8)
    destination = HTTP.serve!("127.0.0.1", 0; listenany=true) do req
        put!(seen, "redirected:" * HTTP.header(req, "Authorization", ""))
        HTTP.Response(204)
    end
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do req
        if req.method == "GET"
            id = HTTP.header(req, "Last-Event-ID", "")
            put!(seen, id)
            isempty(id) && return HTTP.Response(200, ["Content-Type" => "text/event-stream"], "id: first\nretry: 10\n\n")
            return HTTP.Response(307, ["Location" => "http://$(HTTP.server_addr(destination))/redirected"])
        end
        req.method == "DELETE" && return HTTP.Response(204)
        body = JSON3.read(String(req.body), Dict{String,Any})
        haskey(body, "id") || return HTTP.Response(202)
        result = Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict(), "serverInfo" => Dict("name" => "test", "version" => "1"))
        HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "result" => result)))
    end
    client = MCP.connect("http://$(HTTP.server_addr(server))/mcp"; timeout=10, headers=["Authorization" => "Bearer secret"])
    try
        @test timedwait(() -> istaskdone(client.reader), 3) == :ok
        @test [take!(seen), take!(seen)] == ["", "first"]
        @test !isready(seen)
    finally
        close(client); close(server); close(destination)
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

@testset "Response reconnect and competing delivery" begin
    for scenario in (:disconnect, :duplicate, :cancel, :shutdown)
        resumed = Channel{String}(4)
        release = Channel{Nothing}(2)
        reply = Channel{Nothing}(1)
        background = Channel{Any}(1)
        server = HTTP.listen!("127.0.0.1", 0; listenany=true) do io
            req = HTTP.startread(io)
            if req.method == "GET"
                cursor = HTTP.header(req, "Last-Event-ID", "")
                if isempty(cursor)
                    HTTP.setheader(io, "Content-Type" => "text/event-stream")
                    HTTP.startwrite(io)
                    if scenario == :duplicate
                        id = take!(background)
                        take!(reply)
                        write(io, "data: $(JSON3.write(Dict("jsonrpc" => "2.0", "id" => id, "result" => "winner")))\n\n")
                        flush(io)
                        take!(release)
                    else
                        take!(release)
                    end
                else
                    put!(resumed, cursor)
                    if scenario == :disconnect
                        HTTP.setheader(io, "Content-Type" => "text/event-stream")
                        HTTP.startwrite(io)
                        write(io, "data: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":\"resumed\"}\n\n")
                    else
                        take!(release)
                        HTTP.setheader(io, "Content-Type" => "text/event-stream")
                        HTTP.startwrite(io)
                        write(io, "data: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":\"late\"}\n\n")
                    end
                end
            elseif req.method == "DELETE"
                HTTP.setstatus(io, 204); HTTP.startwrite(io)
            else
                body = JSON3.read(String(read(io)), Dict{String,Any})
                method = get(body, "method", "")
                if method == "initialize"
                    result = Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict(), "serverInfo" => Dict("name" => "test", "version" => "1"))
                    HTTP.setheader(io, "Content-Type" => "application/json"); HTTP.startwrite(io)
                    write(io, JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "result" => result)))
                elseif method == "probe"
                    scenario == :duplicate && put!(background, body["id"])
                    HTTP.setheader(io, "Content-Type" => "text/event-stream")
                    HTTP.startwrite(io)
                    write(io, "id: resume\nretry: 0\n\ndata: {\"jsonrpc\":")
                    flush(io)
                    close(io.tracked.conn)
                else
                    HTTP.setstatus(io, 202); HTTP.startwrite(io)
                end
            end
        end
        client = MCP.connect("http://$(HTTP.server_addr(server))/mcp"; timeout=10)
        job = @async MCP.request(client, "probe", Dict())
        try
            @test timedwait(() -> isready(resumed), 5) == :ok
            isready(resumed) || continue
            @test take!(resumed) == "resume"
            if scenario == :disconnect
                @test fetch(job) == "resumed"
            elseif scenario == :duplicate
                put!(reply, nothing)
                @test timedwait(() -> istaskdone(job), 5) == :ok
                @test fetch(job) == "winner"
                @test timedwait(() -> isempty(client.process.requests), 3) == :ok
            elseif scenario == :cancel
                schedule(job, InterruptException(); error=true)
                @test_throws TaskFailedException fetch(job)
                @test timedwait(() -> isempty(client.process.requests), 3) == :ok
            else
                close(client)
                @test fetch(job).kind == :closed
                @test timedwait(() -> isempty(client.process.requests), 3) == :ok
            end
        finally
            put!(release, nothing); put!(release, nothing)
            close(client); close(server)
        end
    end
end

@testset "GET status and exponential backoff" begin
    for status in (400, 401, 403, 404, 405, 418, 503)
        seen = Channel{Float64}(8)
        server = HTTP.serve!("127.0.0.1", 0; listenany=true) do req
            if req.method == "GET"
                put!(seen, time())
                return HTTP.Response(status)
            end
            req.method == "DELETE" && return HTTP.Response(204)
            body = JSON3.read(String(req.body), Dict{String,Any})
            haskey(body, "id") || return HTTP.Response(202)
            result = Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict(), "serverInfo" => Dict("name" => "test", "version" => "1"))
            HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "result" => result)))
        end
        client = MCP.connect("http://$(HTTP.server_addr(server))/mcp"; timeout=10)
        try
            if status == 503
                @test timedwait(() -> length(seen.data) >= 3, 5) == :ok
                times = [take!(seen) for _ in 1:3]
                @test times[2] - times[1] >= 0.9
                @test times[3] - times[2] >= 1.9
            else
                @test timedwait(() -> istaskdone(client.reader), 3) == :ok
                @test length(seen.data) == 1
            end
        finally
            close(client); close(server)
        end
    end
end
