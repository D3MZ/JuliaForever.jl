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
    if request.method == "GET"
        HTTP.setstatus(io, 405)
        HTTP.startwrite(io)
        return
    end
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
