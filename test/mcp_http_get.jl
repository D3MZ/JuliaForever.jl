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
@testset "GET progress and close" begin
    client = MCP.connect("http://$(HTTP.server_addr(server))/mcp"; timeout=2)
    try
        @test timedwait(() -> isready(started), 5) == :ok
        take!(started)
        events = Any[]
        @test MCP.request(client, "probe", Dict(); on_progress=event -> push!(events, event)) == Dict("ok" => true)
        @test [event["progress"] for event in events] == [1]
        close(client)
        @test timedwait(() -> istaskdone(client.reader), 5) == :ok
        @test MCP.request(client, "probe", Dict()).kind == :closed
    finally
        close(client)
        close(messages)
        close(server)
    end
end

@testset "GET unavailability leaves POST usable" begin
    for getresponse in (HTTP.Response(405), HTTP.Response(200, ["Content-Type" => "text/event-stream"], ": end\n\n"), HTTP.Response(200, ["Content-Type" => "text/plain"], "no"))
        gets = Channel{Nothing}(4)
        server = HTTP.serve!("127.0.0.1", 0; listenany=true) do req
            req.method == "GET" && (put!(gets, nothing); return getresponse)
            req.method == "DELETE" && return HTTP.Response(204)
            body = JSON3.read(String(req.body), Dict{String, Any})
            haskey(body, "id") || return HTTP.Response(202)
            result = get(body, "method", "") == "initialize" ? Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict(), "serverInfo" => Dict("name" => "test", "version" => "1")) : Dict("ok" => true)
            HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "result" => result)))
        end
        client = MCP.connect("http://$(HTTP.server_addr(server))/mcp"; timeout=2)
        try
            @test timedwait(() -> istaskdone(client.reader), 5) == :ok
            @test isready(gets)
            take!(gets)
            @test MCP.request(client, "probe", Dict()) == Dict("ok" => true)
            sleep(0.2)
            @test !isready(gets)
        finally
            close(client)
            close(server)
        end
    end
end

@testset "Stalled server response does not block GET or client requests" begin
    waiting = Channel{Nothing}(1)
    probing = Channel{Nothing}(1)
    release = Channel{Nothing}(1)
    progress = Channel{Int}(1)
    server = HTTP.listen!("127.0.0.1", 0; listenany=true) do io
        request = HTTP.startread(io)
        if request.method == "GET"
            HTTP.setheader(io, "Content-Type" => "text/event-stream")
            HTTP.startwrite(io)
            write(io, "data: {\"jsonrpc\":\"2.0\",\"id\":\"server\",\"method\":\"ping\"}\n\n")
            flush(io)
            take!(waiting)
            take!(probing)
            write(io, "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progressToken\":2,\"progress\":1}}\n\n")
            flush(io)
            take!(release)
        elseif request.method == "DELETE"
            HTTP.setstatus(io, 204)
            HTTP.startwrite(io)
        else
            body = JSON3.read(String(read(io)), Dict{String, Any})
            method = get(body, "method", "")
            if get(body, "id", nothing) == "server"
                put!(waiting, nothing)
                take!(release)
                HTTP.setstatus(io, 202)
                HTTP.startwrite(io)
            elseif haskey(body, "id")
                if method == "probe"
                    put!(probing, nothing)
                    sleep(0.5)
                end
                result = method == "initialize" ? Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict(), "serverInfo" => Dict("name" => "test", "version" => "1")) : Dict("ok" => true)
                HTTP.setheader(io, "Content-Type" => "application/json")
                HTTP.startwrite(io)
                write(io, JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "result" => result)))
            else
                HTTP.setstatus(io, 202)
                HTTP.startwrite(io)
            end
        end
    end
    client = MCP.connect("http://$(HTTP.server_addr(server))/mcp"; timeout=2)
    try
        task = @async MCP.request(client, "probe", Dict(); on_progress=event -> put!(progress, event["progress"]))
        @test timedwait(() -> isready(progress), 1) == :ok
        @test timedwait(() -> istaskdone(task), 1) == :ok
        put!(release, nothing)
        put!(release, nothing)
        @test fetch(task) == Dict("ok" => true)
    finally
        close(client)
        close(server)
    end
end

@testset "HTTP shutdown does not follow redirects" begin
    redirected = Channel{Nothing}(1)
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do req
        if req.target == "/redirected"
            put!(redirected, nothing)
            return HTTP.Response(204)
        end
        req.method == "GET" && return HTTP.Response(405)
        req.method == "DELETE" && return HTTP.Response(307, ["Location" => "/redirected"])
        body = JSON3.read(String(req.body), Dict{String, Any})
        haskey(body, "id") || return HTTP.Response(202)
        result = Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict(), "serverInfo" => Dict("name" => "test", "version" => "1"))
        HTTP.Response(200, ["Content-Type" => "application/json", "Mcp-Session-Id" => "session"], JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "result" => result)))
    end
    client = MCP.connect("http://$(HTTP.server_addr(server))/mcp"; timeout=2, headers=["Authorization" => "Bearer secret"])
    try
        close(client)
        @test !isready(redirected)
    finally
        close(client)
        close(server)
    end
end

@testset "A failed server reply cannot fail a client request with the same ID" begin
    probing = Channel{Nothing}(1)
    replied = Channel{Nothing}(1)
    release = Channel{Nothing}(1)
    releaseget = Channel{Nothing}(1)
    server = HTTP.listen!("127.0.0.1", 0; listenany=true) do io
        request = HTTP.startread(io)
        if request.method == "GET"
            HTTP.setheader(io, "Content-Type" => "text/event-stream")
            HTTP.startwrite(io)
            take!(probing)
            write(io, "data: {\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}\n\n")
            flush(io)
            take!(releaseget)
        elseif request.method == "DELETE"
            HTTP.setstatus(io, 204)
            HTTP.startwrite(io)
        else
            body = JSON3.read(String(read(io)), Dict{String, Any})
            method = get(body, "method", "")
            if method == "initialize"
                result = Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict(), "serverInfo" => Dict("name" => "test", "version" => "1"))
                HTTP.setheader(io, "Content-Type" => "application/json")
                HTTP.startwrite(io)
                write(io, JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "result" => result)))
            elseif method == "probe"
                put!(probing, nothing)
                take!(release)
                HTTP.setheader(io, "Content-Type" => "application/json")
                HTTP.startwrite(io)
                write(io, JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "result" => Dict("ok" => true))))
            elseif haskey(body, "id")
                HTTP.setstatus(io, 500)
                HTTP.startwrite(io)
                flush(io)
                put!(replied, nothing)
            else
                HTTP.setstatus(io, 202)
                HTTP.startwrite(io)
            end
        end
    end
    client = MCP.connect("http://$(HTTP.server_addr(server))/mcp"; timeout=5)
    job = @async MCP.request(client, "probe", Dict())
    try
        @test timedwait(() -> isready(replied), 5) == :ok
        @test timedwait(() -> istaskdone(job), 1) == :timed_out
        put!(release, nothing)
        @test timedwait(() -> istaskdone(job), 5) == :ok
        @test fetch(job) == Dict("ok" => true)
    finally
        isready(release) || put!(release, nothing)
        isready(releaseget) || put!(releaseget, nothing)
        close(client)
        close(server)
    end
end

@testset "Accepted response survives a competing HTTP failure" begin
    start = Channel{Int}(1)
    accepted = Channel{Nothing}(1)
    failed = Channel{Nothing}(1)
    release = Base.Event()
    server = HTTP.listen!("127.0.0.1", 0; listenany=true) do io
        req = HTTP.startread(io)
        if req.method == "GET"
            HTTP.setheader(io, "Content-Type" => "text/event-stream"); HTTP.startwrite(io)
            id = take!(start)
            progress = Dict("jsonrpc" => "2.0", "method" => "notifications/progress", "params" => Dict("progressToken" => id, "progress" => 1))
            result = Dict("jsonrpc" => "2.0", "id" => id, "result" => "winner")
            write(io, "data: $(JSON3.write(progress))\n\ndata: $(JSON3.write(result))\n\n"); flush(io)
            wait(release)
        elseif req.method == "DELETE"
            HTTP.setstatus(io, 204); HTTP.startwrite(io)
        else
            body = JSON3.read(String(read(io)), Dict{String,Any})
            if get(body, "method", "") == "initialize"
                result = Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict(), "serverInfo" => Dict("name" => "test", "version" => "1"))
                HTTP.setheader(io, "Content-Type" => "application/json"); HTTP.startwrite(io)
                write(io, JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "result" => result)))
            elseif get(body, "method", "") == "probe"
                put!(start, body["id"])
                take!(accepted)
                HTTP.setstatus(io, 400); HTTP.startwrite(io); flush(io)
                put!(failed, nothing)
            else
                HTTP.setstatus(io, 202); HTTP.startwrite(io)
            end
        end
    end
    client = MCP.connect("http://$(HTTP.server_addr(server))/mcp"; timeout=10)
    job = @async MCP.request(client, "probe", Dict(); on_progress=_ -> wait(release))
    try
        @test timedwait(() -> lock(() -> any(p -> p.progress isa MCP.Finishing, values(client.pending)), client.lock), 5) == :ok
        put!(accepted, nothing)
        @test timedwait(() -> isready(failed), 5) == :ok
        @test timedwait(() -> lock(() -> isempty(client.process.requests), client.lock), 5) == :ok
        @test !istaskdone(job)
        notify(release)
        @test timedwait(() -> istaskdone(job), 5) == :ok
        @test fetch(job) == "winner"
    finally
        notify(release)
        close(client); close(server)
    end
end
