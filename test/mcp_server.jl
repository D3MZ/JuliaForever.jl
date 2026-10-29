using JSON3

mode = ARGS[1]
marker = ARGS[2]
held = Any[]
cancelled = Ref(false)
requests = Dict{String, Any}()
initialized = Ref(false)

function send(message)
    println(stdout, JSON3.write(message))
    flush(stdout)
end

reply(id, result) = send(Dict("jsonrpc" => "2.0", "id" => id, "result" => result))
fault(id, code, message) = send(Dict("jsonrpc" => "2.0", "id" => id, "error" => Dict("code" => code, "message" => message)))

while !eof(stdin)
    message = JSON3.read(readline(stdin), Dict{String, Any})
    if !haskey(message, "method")
        requests[string(message["id"])] = message
        continue
    end
    method = message["method"]
    if method == "initialize"
        params = message["params"]
        if params["protocolVersion"] != "2025-11-25" || !isempty(params["capabilities"]) || params["clientInfo"]["name"] != "JuliaForever"
            fault(message["id"], -32602, "invalid initialize")
            continue
        end
        version = get(Dict("badversion" => "2099-01-01", "oldversion" => "2025-06-18", "oldversion2" => "2025-03-26", "oldversion3" => "2024-11-05"), mode, "2025-11-25")
        capabilities = mode == "no_tools" ? Dict() : mode == "badcap" ? Dict("tools" => nothing) : Dict("tools" => Dict("listChanged" => true))
        reply(message["id"], Dict("protocolVersion" => version, "capabilities" => capabilities, "serverInfo" => Dict("name" => "mock", "version" => "1")))
    elseif method == "notifications/initialized"
        initialized[] = true
        send(Dict("jsonrpc" => "2.0", "id" => "server-ping", "method" => "ping"))
        send(Dict("jsonrpc" => "2.0", "id" => "server-unknown", "method" => "unsupported"))
    elseif method == "notifications/cancelled"
        cancelled[] = true
    elseif method == "tools/list"
        if !initialized[]
            fault(message["id"], -32600, "not initialized")
            continue
        end
        cursor = get(get(message, "params", Dict()), "cursor", nothing)
        if mode == "loopcursor"
            reply(message["id"], Dict("tools" => [], "nextCursor" => "same"))
        elseif mode == "collisions"
            reply(message["id"], Dict("tools" => [Dict("name" => "a.b", "inputSchema" => Dict("type" => "object")), Dict("name" => "a_b", "inputSchema" => Dict("type" => "object"))]))
        elseif mode == "badcursor"
            reply(message["id"], Dict("tools" => [], "nextCursor" => nothing))
        elseif mode == "taskrequired"
            reply(message["id"], Dict("tools" => [Dict("name" => "long_task", "inputSchema" => Dict("type" => "object"), "execution" => Dict("taskSupport" => "required"))]))
        elseif isnothing(cursor)
            reply(message["id"], Dict("tools" => [Dict("name" => "alpha", "description" => "First", "inputSchema" => Dict("type" => "object", "properties" => Dict("value" => Dict("type" => "integer"))))], "nextCursor" => "opaque/+="))
        elseif cursor == "opaque/+="
            reply(message["id"], Dict("tools" => [Dict("name" => "second.test", "inputSchema" => Dict("type" => "object"))]))
        else
            fault(message["id"], -32602, "invalid cursor")
        end
    elseif method == "tools/call"
        name = message["params"]["name"]
        args = get(message["params"], "arguments", Dict())
        if name == "reverse"
            push!(held, message)
            if length(held) == 3
                if mode == "eof"
                    exit(0)
                end
                for item in reverse(held)
                    reply(item["id"], Dict("content" => [Dict("type" => "text", "text" => string(item["params"]["arguments"]["value"]))]))
                end
                empty!(held)
            end
        elseif name == "hold" || name == "timeout"
            name == "timeout" && push!(held, message)
            write(marker, "started")
        elseif name == "protocol_error"
            fault(message["id"], -32602, "bad arguments")
        elseif name == "invalid_error"
            fault(message["id"], true, "invalid code")
        elseif name == "tool_error"
            reply(message["id"], Dict("content" => [Dict("type" => "text", "text" => "tool failed")], "isError" => true))
        elseif name == "mixed"
            reply(message["id"], Dict("content" => [Dict("type" => "text", "text" => "hello"), Dict("type" => "resource_link", "uri" => "file:///item", "name" => "item")], "structuredContent" => Dict("value" => 3)))
        elseif name == "check_cancelled"
            for item in held
                reply(item["id"], Dict("content" => []))
            end
            empty!(held)
            reply(message["id"], Dict("content" => [], "structuredContent" => Dict("cancelled" => cancelled[])))
        elseif name == "check_requests"
            reply(message["id"], Dict("content" => [], "structuredContent" => requests))
        elseif name == "invalid_result"
            reply(message["id"], [1, 2])
        elseif mode == "incomplete"
            print(stdout, JSON3.write(Dict("jsonrpc" => "2.0", "id" => message["id"], "result" => Dict("content" => []))))
            flush(stdout)
            exit(0)
        elseif mode == "malformed"
            println(stdout, "not json")
            flush(stdout)
        else
            reply(message["id"], Dict("content" => [Dict("type" => "text", "text" => string(name, ":", get(args, "value", "")))]))
        end
    end
end
