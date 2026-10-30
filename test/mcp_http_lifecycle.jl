using Test, HTTP, JSON3, JuliaForever
const MCP = JuliaForever.MCP

@testset "HTTP close cancels stalled server replies" begin
    for timeout in (0, Inf)
        started = Channel{Nothing}(1)
        release = Channel{Nothing}(2)
        server = HTTP.listen!("127.0.0.1", 0; listenany=true) do io
            req = HTTP.startread(io)
            if req.method == "GET"
                HTTP.setheader(io, "Content-Type" => "text/event-stream")
                HTTP.startwrite(io)
                write(io, "data: {\"jsonrpc\":\"2.0\",\"id\":\"server\",\"method\":\"ping\"}\n\n")
                flush(io)
                take!(release)
            elseif req.method == "DELETE"
                HTTP.setstatus(io, 204); HTTP.startwrite(io)
            else
                body = JSON3.read(String(read(io)), Dict{String,Any})
                if get(body, "id", nothing) == "server"
                    put!(started, nothing)
                    take!(release)
                    HTTP.setstatus(io, 202); HTTP.startwrite(io)
                elseif get(body, "method", "") == "initialize"
                    HTTP.setheader(io, "Content-Type" => "application/json")
                    HTTP.setheader(io, "Mcp-Session-Id" => "s")
                    HTTP.startwrite(io)
                    write(io, JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "result" => Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict(), "serverInfo" => Dict("name" => "test", "version" => "1")))))
                else
                    HTTP.setstatus(io, 202); HTTP.startwrite(io)
                end
            end
        end
        client = MCP.connect("http://$(HTTP.server_addr(server))/mcp"; timeout=0)
        client.timeout = timeout
        try
            @test timedwait(() -> isready(started), 5) == :ok
            task = @async close(client)
            @test timedwait(() -> istaskdone(task), 3) == :ok
            @test timedwait(() -> istaskdone(client.reader), 2) == :ok
            @test isempty(client.process.replies)
        finally
            put!(release, nothing); put!(release, nothing)
            close(server)
        end
    end
end

@testset "SSE input is bounded" begin
    limit = 16 * 1024 * 1024
    for input in ("data: " * repeat("x", limit + 1), repeat("data: " * repeat("x", 1024) * "\n", div(limit, 1025) + 1))
        stream = IOBuffer(input)
        @test MCP.sseread!(nothing, stream, MCP.ServerStream()) === false
    end
end

@testset "Progress backlog and received reply survive close" begin
    entered = Channel{Nothing}(1)
    release = Channel{Nothing}(1)
    server = HTTP.listen!("127.0.0.1", 0; listenany=true) do io
        req = HTTP.startread(io)
        if req.method == "GET"
            HTTP.setstatus(io, 405); HTTP.startwrite(io)
        elseif req.method == "DELETE"
            HTTP.setstatus(io, 204); HTTP.startwrite(io)
        else
            body = JSON3.read(String(read(io)), Dict{String,Any})
            method = get(body, "method", "")
            if method == "initialize"
                HTTP.setheader(io, "Content-Type" => "application/json")
                HTTP.startwrite(io)
                write(io, JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "result" => Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict(), "serverInfo" => Dict("name" => "test", "version" => "1")))))
            elseif method == "probe"
                HTTP.setheader(io, "Content-Type" => "text/event-stream")
                HTTP.startwrite(io)
                for n in 1:200
                    message = Dict("jsonrpc" => "2.0", "method" => "notifications/progress", "params" => Dict("progressToken" => body["id"], "progress" => n))
                    write(io, "data: $(JSON3.write(message))\n\n")
                    flush(io)
                    n == 1 && take!(entered)
                end
                write(io, "data: $(JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "result" => Dict("ok" => true))))\n\n")
                flush(io)
            else
                HTTP.setstatus(io, 202); HTTP.startwrite(io)
            end
        end
    end
    client = MCP.connect("http://$(HTTP.server_addr(server))/mcp"; timeout=0)
    events = Int[]
    job = @async MCP.request(client, "probe", Dict(); on_progress=event -> begin
        push!(events, event["progress"])
        if length(events) == 1
            put!(entered, nothing)
            take!(release)
        end
    end)
    try
        @test timedwait(() -> any(p -> p.progress isa MCP.Finishing, values(client.pending)), 10) == :ok
        close(client)
        put!(release, nothing)
        @test timedwait(() -> istaskdone(job), 5) == :ok
        @test fetch(job) == Dict("ok" => true)
        @test events == collect(1:200)
    finally
        isready(release) || put!(release, nothing)
        close(client)
        close(server)
    end
end

@testset "SSE fragmented lines and carriage returns" begin
    seen = Channel{String}(4)
    server = HTTP.listen!("127.0.0.1", 0; listenany=true) do io
        req = HTTP.startread(io)
        if req.method == "GET"
            HTTP.setheader(io, "Content-Type" => "text/event-stream")
            HTTP.startwrite(io)
            write(io, "event: message\r\r\ndata: {\"jsonrpc\":\"2.0\",\"id\":\"ignored\",\"method\":\"ping\"}\n\n")
            for part in ("event: mes", "sage\r\ndata: {\"jsonrpc\":\"2.0\",", "\ndata: \"id\":\"valid\",\"method\":\"ping\"}\r\n\r\n")
                write(io, part); flush(io); sleep(0.03)
            end
        elseif req.method == "DELETE"
            HTTP.setstatus(io, 204); HTTP.startwrite(io)
        else
            body = JSON3.read(String(read(io)), Dict{String,Any})
            if get(body, "method", "") == "initialize"
                HTTP.setheader(io, "Content-Type" => "application/json"); HTTP.startwrite(io)
                write(io, JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "result" => Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict(), "serverInfo" => Dict("name" => "test", "version" => "1")))))
            else
                haskey(body, "id") && put!(seen, string(body["id"]))
                HTTP.setstatus(io, 202); HTTP.startwrite(io)
            end
        end
    end
    client = MCP.connect("http://$(HTTP.server_addr(server))/mcp"; timeout=2)
    try
        @test timedwait(() -> isready(seen), 5) == :ok
        @test take!(seen) == "valid"
        @test !isready(seen)
    finally
        close(client); close(server)
    end
end

@testset "HTTP retains a slow progress backlog" begin
    entered = Channel{Nothing}(1)
    release = Channel{Nothing}(1)
    server = HTTP.listen!("127.0.0.1", 0; listenany=true) do io
        req = HTTP.startread(io)
        if req.method == "GET"
            HTTP.setstatus(io, 405); HTTP.startwrite(io)
        elseif req.method == "DELETE"
            HTTP.setstatus(io, 204); HTTP.startwrite(io)
        else
            body = JSON3.read(String(read(io)), Dict{String,Any})
            method = get(body, "method", "")
            if method == "initialize"
                HTTP.setheader(io, "Content-Type" => "application/json"); HTTP.startwrite(io)
                write(io, JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "result" => Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict(), "serverInfo" => Dict("name" => "test", "version" => "1")))))
            elseif method == "probe"
                HTTP.setheader(io, "Content-Type" => "text/event-stream"); HTTP.startwrite(io)
                for n in 1:300
                    message = Dict("jsonrpc" => "2.0", "method" => "notifications/progress", "params" => Dict("progressToken" => body["id"], "progress" => n))
                    write(io, "data: $(JSON3.write(message))\n\n"); flush(io)
                    n == 1 && take!(entered)
                end
                write(io, "data: $(JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "result" => Dict("ok" => true))))\n\n")
                flush(io)
            else
                HTTP.setstatus(io, 202); HTTP.startwrite(io)
            end
        end
    end
    client = MCP.connect("http://$(HTTP.server_addr(server))/mcp"; timeout=0)
    events = Int[]
    job = @async MCP.request(client, "probe", Dict(); on_progress=event -> begin
        push!(events, event["progress"])
        if event["progress"] == 1
            put!(entered, nothing)
            take!(release)
        end
    end)
    try
        received() = lock(() -> any(p -> p.progress isa MCP.Finishing, values(client.pending)), client.lock)
        @test timedwait(() -> istaskdone(job) || received(), 10) == :ok
        @test !istaskdone(job)
        put!(release, nothing)
        @test timedwait(() -> istaskdone(job), 10) == :ok
        @test fetch(job) == Dict("ok" => true)
        @test events == collect(1:300)
    finally
        isready(release) || put!(release, nothing)
        close(client); close(server)
    end
end

@testset "HTTP server request overload closes the connection" begin
    for method in ("ping", "roots/list")
        beginstream = Channel{Nothing}(1)
        release = Channel{Nothing}(1)
        server = HTTP.listen!("127.0.0.1", 0; listenany=true) do io
            req = HTTP.startread(io)
            if req.method == "GET"
                HTTP.setheader(io, "Content-Type" => "text/event-stream"); HTTP.startwrite(io)
                take!(beginstream)
                for n in 1:257
                    message = Dict("jsonrpc" => "2.0", "id" => "server-$n", "method" => method)
                    write(io, "data: $(JSON3.write(message))\n\n"); flush(io)
                end
            elseif req.method == "DELETE"
                HTTP.setstatus(io, 204); HTTP.startwrite(io)
            else
                body = JSON3.read(String(read(io)), Dict{String,Any})
                if get(body, "method", "") == "initialize"
                    HTTP.setheader(io, "Content-Type" => "application/json"); HTTP.startwrite(io)
                    write(io, JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "result" => Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict(), "serverInfo" => Dict("name" => "test", "version" => "1")))))
                elseif !haskey(body, "id")
                    HTTP.setstatus(io, 202); HTTP.startwrite(io)
                elseif get(body, "method", "") == "probe"
                    put!(beginstream, nothing)
                    wait(release)
                    HTTP.setstatus(io, 202); HTTP.startwrite(io)
                else
                    wait(release)
                    HTTP.setstatus(io, 202); HTTP.startwrite(io)
                end
            end
        end
        roots = () -> (wait(release); [])
        client = MCP.connect("http://$(HTTP.server_addr(server))/mcp"; timeout=0, roots)
        job = @async MCP.request(client, "probe", Dict())
        try
            done = timedwait(() -> istaskdone(job), 20) == :ok
            @test done
            result = done ? fetch(job) : nothing
            @test result isa MCP.Failure && result.kind == :overload
            @test client.state == :closed
        finally
            close(release)
            close(client); close(server)
        end
    end
end
