using Test, HTTP, JSON3, JuliaForever
const MCP = JuliaForever.MCP

function faultevent(method, id)
    Dict(
        "malformed" => "data: {synthetic-secret\n\n",
        "trailing" => "data: $(JSON3.write(Dict("jsonrpc" => "2.0", "id" => id, "result" => "wrong"))) garbage\n\n",
        "control" => "data: {\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":\"wrong\tvalue\"}\n\n",
        "leading_zero" => "data: {\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":01}\n\n",
        "trailing_decimal" => "data: {\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":1.}\n\n",
        "negative_infinity" => "data: {\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":-Infinity}\n\n",
        "nonobject" => "data: []\n\n",
        "bad_error" => "data: $(JSON3.write(Dict("jsonrpc" => "2.0", "id" => id, "error" => Dict("code" => true, "message" => "invalid"))))\n\n",
        "null_error" => "data: $(JSON3.write(Dict("jsonrpc" => "2.0", "id" => id, "error" => nothing)))\n\n",
        "bad_version" => "data: $(JSON3.write(Dict("jsonrpc" => "1.0", "id" => id, "result" => "wrong")))\n\n",
        "ambiguous" => "data: $(JSON3.write(Dict("jsonrpc" => "2.0", "id" => id, "error" => nothing, "result" => "wrong")))\n\n",
        "whitespace" => "data:    \n\n",
        "ignored" => "event: other\ndata: $(JSON3.write(Dict("jsonrpc" => "2.0", "id" => id, "result" => "wrong")))\n\n",
        "foreign_id" => "data: $(JSON3.write(Dict("jsonrpc" => "2.0", "id" => id + 1000, "result" => "wrong")))\n\n",
        "multiline" => ": keepalive\n\n",
        "duplicate_keys" => ": keepalive\n\n",
        "deep" => "data: {\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"scenario\":\"deep\",\"nested\":" * repeat("[", 600) * "0" * repeat("]", 600) * "}}\n\n",
        "deep_edge" => ": keepalive\n\n",
        "deep_guard" => "data: {\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":" * repeat("[", 20000) * "0" * repeat("]", 20000) * "}\n\n",
        "valid_error" => ": keepalive\n\n",
    )[method]
end

function expectedresult(method)
    nested = method == "deep_edge" ? foldl((value, _) -> Any[value], 1:510; init=0) : Any[Dict("text" => "quoted \"}[]\\\n🐱")]
    Dict("scenario" => method, "nested" => nested)
end
function goodevent(method, id)
    method == "valid_error" && return "data: $(JSON3.write(Dict("jsonrpc" => "2.0", "id" => id, "error" => Dict("code" => -32001, "message" => "request failed"))))\n\n"
    result = expectedresult(method)
    method == "multiline" && return "data: {\"jsonrpc\":\"2.0\",\ndata: \"id\":$id, \"result\":$(JSON3.write(result))}\n\n"
    method == "duplicate_keys" && return "data: {\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":\"wrong\",\"result\":$(JSON3.write(result))}\n\n"
    "data: $(JSON3.write(Dict("jsonrpc" => "2.0", "id" => id, "result" => result)))\n\n"
end
function checkresult(result, method)
    if method == "valid_error"
        @test result isa MCP.Failure && result.kind == :rpc && result.message == "request failed"
    else
        @test result == expectedresult(method)
    end
end
function checkoracle(result, method, count)
    if method == "deep"
        @test result["result"] == Dict("scenario" => "deep", "nested" => foldl((value, _) -> Any[value], 1:600; init=0))
    elseif method == "valid_error"
        @test result["error"]["code"] == -32001 && result["error"]["message"] == "request failed"
    else
        @test result["result"] == expectedresult(method)
    end
    @test result["errors"] == count
end

@testset "MCP SSE event validation" begin
@testset "POST SSE skips malformed events without losing its response" begin
    scenarios = ("malformed", "trailing", "control", "leading_zero", "trailing_decimal", "negative_infinity", "nonobject", "bad_error", "null_error", "bad_version", "ambiguous", "whitespace", "ignored", "foreign_id", "multiline", "duplicate_keys", "deep", "deep_edge", "valid_error")
    errors = Set(("malformed", "trailing", "control", "leading_zero", "trailing_decimal", "negative_infinity", "nonobject", "bad_error", "null_error", "bad_version", "ambiguous"))
    server = HTTP.listen!("127.0.0.1", 0; listenany=true) do io
        req = HTTP.startread(io)
        if req.method == "GET"
            HTTP.setstatus(io, 405); HTTP.startwrite(io)
        elseif req.method == "DELETE"
            HTTP.setstatus(io, 204); HTTP.startwrite(io)
        else
            body = JSON3.read(read(io), Dict{String, Any})
            method = get(body, "method", "")
            if method == "initialize"
                result = Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict(), "serverInfo" => Dict("name" => "fixture", "version" => "1"))
                HTTP.setheader(io, "Content-Type" => "application/json"); HTTP.startwrite(io)
                write(io, JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "result" => result)))
            elseif method in (scenarios..., "deep_guard")
                id = body["id"]
                HTTP.setheader(io, "Content-Type" => "text/event-stream"); HTTP.startwrite(io)
                try
                    for part in (faultevent(method, id), goodevent(method, id))
                        write(io, part); flush(io)
                    end
                catch
                end
            else
                HTTP.setstatus(io, 202); HTTP.startwrite(io)
            end
        end
    end
    url = "http://$(HTTP.server_addr(server))/mcp"
    client = MCP.connect(url; timeout=2)
    try
        @test client isa MCP.Client
        for method in (scenarios..., "deep_guard", "multiline")
            checkresult(MCP.request(client, method, Dict()), method)
        end
        @test isempty(client.pending)
        if haskey(ENV, "PI_SOURCE")
            @test readchomp(`git -C $(ENV["PI_SOURCE"]) rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
            script = joinpath(@__DIR__, "mcp_post_sse_pi.mjs")
            env = Dict("PI_SOURCE" => ENV["PI_SOURCE"], "JF_HTTP_URL" => url)
            oracle = @async read(addenv(`node $script $scenarios`, env), String)
            @test timedwait(() -> istaskdone(oracle), 15) == :ok
            expected = JSON3.read(fetch(oracle), Dict{String, Any})
            for method in scenarios
                checkoracle(expected[method], method, Int(method in errors))
            end
        end
    finally
        close(client); close(server)
    end
end

@testset "GET SSE validates events before resolving a request" begin
    scenarios = ("malformed", "trailing", "control", "leading_zero", "trailing_decimal", "negative_infinity", "bad_error", "null_error", "whitespace", "ignored", "foreign_id", "multiline", "duplicate_keys", "deep", "deep_edge", "valid_error")
    errors = Set(("malformed", "trailing", "control", "leading_zero", "trailing_decimal", "negative_infinity", "bad_error", "null_error"))
    queued = Channel{Any}(16)
    release = Channel{Nothing}(16)
    finished = Channel{Nothing}(2)
    server = HTTP.listen!("127.0.0.1", 0; listenany=true) do io
        req = HTTP.startread(io)
        if req.method == "GET"
            HTTP.setheader(io, "Content-Type" => "text/event-stream"); HTTP.startwrite(io)
            try
                while true
                    item = take!(queued)
                    item === nothing && break
                    id, method = item
                    for part in (faultevent(method, id), goodevent(method, id))
                        write(io, part); flush(io)
                    end
                end
            catch
            finally
                put!(finished, nothing)
            end
        elseif req.method == "DELETE"
            put!(queued, nothing)
            HTTP.setstatus(io, 204); HTTP.startwrite(io)
        elseif endswith(req.target, "/release")
            put!(release, nothing)
            HTTP.setstatus(io, 204); HTTP.startwrite(io)
        else
            body = JSON3.read(read(io), Dict{String, Any})
            method = get(body, "method", "")
            HTTP.setheader(io, "Mcp-Session-Id" => "fixture")
            if method == "initialize"
                result = Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict(), "serverInfo" => Dict("name" => "fixture", "version" => "1"))
                HTTP.setheader(io, "Content-Type" => "application/json"); HTTP.startwrite(io)
                write(io, JSON3.write(Dict("jsonrpc" => "2.0", "id" => body["id"], "result" => result)))
            elseif method in (scenarios..., "deep_guard")
                HTTP.setheader(io, "Content-Type" => "text/event-stream"); HTTP.startwrite(io)
                write(io, ": pending\n\n"); flush(io)
                put!(queued, (body["id"], method))
                take!(release)
            else
                HTTP.setstatus(io, 202); HTTP.startwrite(io)
            end
        end
    end
    url = "http://$(HTTP.server_addr(server))/mcp"
    client = MCP.connect(url; timeout=2)
    try
        for method in (scenarios..., "deep_guard", "multiline")
            checkresult(MCP.request(client, method, Dict()), method)
            put!(release, nothing)
        end
        close(client)
        @test timedwait(() -> isready(finished), 3) == :ok
        isready(finished) && take!(finished)
        if haskey(ENV, "PI_SOURCE")
            script = joinpath(@__DIR__, "mcp_post_sse_pi.mjs")
            env = Dict("PI_SOURCE" => ENV["PI_SOURCE"], "JF_HTTP_URL" => url, "JF_GET_STREAM" => "1")
            oracle = @async read(addenv(`node $script $scenarios`, env), String)
            @test timedwait(() -> istaskdone(oracle), 20) == :ok
            expected = JSON3.read(fetch(oracle), Dict{String, Any})
            for method in scenarios
                checkoracle(expected[method], method, Int(method in errors))
            end
        end
    finally
        close(client)
        put!(queued, nothing); put!(release, nothing)
        close(server)
    end
end
end
