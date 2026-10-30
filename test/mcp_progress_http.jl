using Test, HTTP, JSON3, JuliaForever
const MCP = JuliaForever.MCP
takebefore(channel) = timedwait(() -> isready(channel), 15) == :ok ? take!(channel) : error("timed out waiting for callback")
fetchbefore(task) = timedwait(() -> istaskdone(task), 15) == :ok ? fetch(task) : error("timed out waiting for request")

function event!(io, message)
    write(io, "data: $(JSON3.write(message))\n\n")
    flush(io)
end

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
        result = Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict("tools" => Dict()), "serverInfo" => Dict("name" => "test", "version" => "1"))
        HTTP.setheader(io, "Content-Type" => "application/json")
        HTTP.setheader(io, "Mcp-Session-Id" => "session")
        HTTP.startwrite(io)
        write(io, JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "result" => result)))
    elseif !haskey(body, "id")
        HTTP.setstatus(io, 202)
        HTTP.startwrite(io)
    else
        HTTP.setheader(io, "Content-Type" => "text/event-stream")
        HTTP.startwrite(io)
        id = body["id"]
        try
            if method in ("timeout", "close")
                sleep(0.1)
                event!(io, Dict("jsonrpc" => "2.0", "method" => "notifications/progress", "params" => Dict("progressToken" => id, "progress" => 1)))
                sleep(1)
                event!(io, Dict("jsonrpc" => "2.0", "method" => "notifications/progress", "params" => Dict("progressToken" => id, "progress" => 99)))
                return
            end
            for step in 1:3
                sleep(0.25)
                event!(io, Dict("jsonrpc" => "2.0", "method" => "notifications/progress", "params" => Dict("progressToken" => id, "progress" => step, "message" => method)))
            end
            sleep(0.25)
            method == "missing" || event!(io, Dict("jsonrpc" => "2.0", "id" => id, "result" => Dict("method" => method)))
        catch
        end
    end
end

@testset "MCP HTTP SSE progress" begin
    client = MCP.connect("http://$(HTTP.server_addr(server))/mcp"; timeout=10)
    @test client isa MCP.Client
    client.timeout = 0.6
    try
        events = [Any[], Any[]]
        jobs = [@async MCP.request(client, "stream$index", Dict(); timeout=0.6, on_progress=event -> push!(events[index], event)) for index in 1:2]
        @test fetch.(jobs) == [Dict("method" => "stream1"), Dict("method" => "stream2")]
        @test [[event["progress"] for event in group] for group in events] == [[1, 2, 3], [1, 2, 3]]
        @test [[event["message"] for event in group] for group in events] == [["stream1", "stream1", "stream1"], ["stream2", "stream2", "stream2"]]
        @test length(unique([only(unique(event["progressToken"] for event in group)) for group in events])) == 2
        missing = Any[]
        @test MCP.request(client, "missing", Dict(); timeout=0.6, on_progress=event -> push!(missing, event)).kind == :protocol
        @test [event["progress"] for event in missing] == [1, 2, 3]
        @test timedwait(() -> isempty(client.process.requests), 2) == :ok
        timeout = Any[]
        @test MCP.request(client, "timeout", Dict(); timeout=0.3, on_progress=event -> push!(timeout, event)).kind == :timeout
        @test timedwait(() -> isempty(client.process.requests), 2) == :ok
        sleep(0.9)
        @test [event["progress"] for event in timeout] == [1]
        entered = Channel{Nothing}(1)
        cancelled = Any[]
        job = @async MCP.request(client, "close", Dict(); on_progress=event -> begin
            push!(cancelled, event)
            put!(entered, nothing)
        end)
        takebefore(entered)
        schedule(job, InterruptException(); error=true)
        @test_throws TaskFailedException fetchbefore(job)
        @test timedwait(() -> isempty(client.process.requests), 2) == :ok
        sleep(0.9)
        @test [event["progress"] for event in cancelled] == [1]
        entered = Channel{Nothing}(1)
        closed = Any[]
        job = @async MCP.request(client, "close", Dict(); on_progress=event -> begin
            push!(closed, event)
            put!(entered, nothing)
        end)
        takebefore(entered)
        close(client)
        @test fetchbefore(job).kind == :closed
        @test timedwait(() -> isempty(client.process.requests), 2) == :ok
        sleep(0.9)
        @test [event["progress"] for event in closed] == [1]
    finally
        close(client)
        close(server)
    end
end
