using JSON3

mode, marker = ARGS
send(message) = (println(stdout, JSON3.write(message)); flush(stdout))
reply(id, result) = send(Dict("jsonrpc" => "2.0", "id" => id, "result" => result))
fault(id, code, message) = send(Dict("jsonrpc" => "2.0", "id" => id, "error" => Dict("code" => code, "message" => message)))

for line in eachline(stdin)
    message = JSON3.read(line, Dict{String, Any})
    method = get(message, "method", "")
    if method == "initialize"
        capabilities = mode == "no_resources" ? Dict() : mode == "badcap" ? Dict("resources" => nothing) : Dict("resources" => Dict("listChanged" => true))
        reply(message["id"], Dict("protocolVersion" => "2025-11-25", "capabilities" => capabilities, "serverInfo" => Dict("name" => "mock", "version" => "1")))
    elseif method == "notifications/cancelled"
        write(marker * ".cancelled", "cancelled")
    elseif method == "resources/list"
        cursor = get(get(message, "params", Dict()), "cursor", nothing)
        if mode == "limit"
            next = isnothing(cursor) ? 1 : parse(Int, cursor) + 1
            reply(message["id"], Dict("resources" => [], "nextCursor" => string(next)))
        elseif mode == "loop"
            reply(message["id"], Dict("resources" => [], "nextCursor" => "repeat"))
        elseif mode == "badcursor"
            reply(message["id"], Dict("resources" => [], "nextCursor" => 3))
        elseif mode == "badentry"
            reply(message["id"], Dict("resources" => [Dict("name" => "missing uri")]))
        elseif mode == "hold"
            write(marker, "started")
        elseif isnothing(cursor)
            reply(message["id"], Dict("resources" => [Dict("uri" => "docs://intro", "name" => "Intro", "mimeType" => "text/plain", "description" => "A guide", "_meta" => Dict("private" => 1), "icons" => [Dict("src" => "icon")]), Dict("uri" => "ui://viewer", "name" => "Viewer"), Dict("uri" => "docs://app", "name" => "App", "mimeType" => "text/html; profile=\"mcp-app\"")], "nextCursor" => "opaque/+=", "ignored" => 1))
        elseif cursor == "opaque/+="
            reply(message["id"], Dict("resources" => [Dict("uri" => "docs://image", "mimeType" => "image/png")], "nextCursor" => nothing))
        else
            fault(message["id"], -32602, "bad cursor")
        end
    elseif method == "resources/templates/list"
        if mode == "no_templates"
            fault(message["id"], -32601, "Method not found")
        else
            reply(message["id"], Dict("resourceTemplates" => [Dict("uriTemplate" => "docs://{id}", "description" => "A page")], "nextCursor" => ""))
        end
    elseif method == "resources/read"
        uri = message["params"]["uri"]
        if uri == "docs://missing"
            fault(message["id"], -32002, "Resource not found")
        elseif uri == "docs://invalid"
            reply(message["id"], Dict("contents" => [Dict("uri" => uri)]))
        elseif uri == "docs://wait"
            write(marker, "started")
        elseif uri == "docs://empty"
            reply(message["id"], Dict("contents" => []))
        elseif uri == "docs://multi"
            reply(message["id"], Dict("contents" => [Dict("uri" => "docs://a", "text" => "one"), Dict("uri" => "docs://b", "text" => "two")]))
        elseif uri == "docs://image"
            reply(message["id"], Dict("contents" => [Dict("uri" => uri, "mimeType" => "image/png", "blob" => "aGVsbG8=")]))
        else
            reply(message["id"], Dict("contents" => [Dict("uri" => uri, "mimeType" => "text/plain", "text" => "hello: $uri", "_meta" => Dict("private" => 2))], "extra" => true))
        end
    end
end
