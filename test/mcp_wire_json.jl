using Test, HTTP, JSON3, JuliaForever
const MCP = JuliaForever.MCP

function wireerror(method, id)
    wrong = JSON3.write(Dict("jsonrpc" => "2.0", "id" => id, "result" => "wrong"))
    Dict(
        "trailing" => wrong * " garbage",
        "malformed" => "{synthetic-secret",
        "control" => "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":\"bad\tvalue\"}",
        "leading_zero" => "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":01}",
        "bad_error" => JSON3.write(Dict("jsonrpc" => "2.0", "id" => id, "error" => Dict("code" => true, "message" => "invalid"))),
        "null_error" => JSON3.write(Dict("jsonrpc" => "2.0", "id" => id, "error" => nothing)),
        "bad_version" => JSON3.write(Dict("jsonrpc" => "1.0", "id" => id, "result" => "wrong")),
        "ambiguous" => JSON3.write(Dict("jsonrpc" => "2.0", "id" => id, "result" => "wrong", "error" => nothing)),
        "nonobject" => "null",
        "deep_guard" => "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":" * repeat("[", 20000) * "0" * repeat("]", 20000) * "}",
    )[method]
end

function wireoracle(mode, url, scenarios)
    script = joinpath(@__DIR__, "mcp_wire_json_pi.mjs")
    env = Dict("PI_SOURCE" => ENV["PI_SOURCE"], "JF_WIRE_MODE" => mode, "JF_HTTP_URL" => url, "JF_STDIO_SERVER" => joinpath(@__DIR__, "mcp_wire_stdio_server.mjs"))
    task = @async read(addenv(`node $script $scenarios`, env), String)
    @test timedwait(() -> istaskdone(task), 20) == :ok
    JSON3.read(fetch(task), Dict{String, Any})
end

@testset "MCP JSON message boundaries" begin
@testset "HTTP JSON rejects malformed documents without leaking their contents" begin
    errors = ("trailing", "malformed", "control", "leading_zero", "bad_error", "null_error", "bad_version", "ambiguous", "nonobject")
    scenarios = (errors..., "valid", "valid_error")
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do req
        req.method == "GET" && return HTTP.Response(405)
        req.method == "DELETE" && return HTTP.Response(204)
        body = JSON3.read(String(req.body), Dict{String, Any})
        haskey(body, "id") || return HTTP.Response(202)
        method, id = body["method"], body["id"]
        if method == "initialize"
            result = Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict(), "serverInfo" => Dict("name" => "fixture", "version" => "1"))
            return HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(Dict("jsonrpc" => "2.0", "id" => id, "result" => result)))
        end
        response = method in (errors..., "deep_guard") ? wireerror(method, id) : method == "valid_error" ? JSON3.write(Dict("jsonrpc" => "2.0", "id" => id, "error" => Dict("code" => -32001, "message" => "request failed"))) : JSON3.write(Dict("jsonrpc" => "2.0", "id" => id, "result" => Dict("scenario" => method)))
        HTTP.Response(200, ["Content-Type" => "application/json"], response)
    end
    url = "http://$(HTTP.server_addr(server))/mcp"
    client = MCP.connect(url; timeout=15)
    try
        @test client isa MCP.Client
        for method in (errors..., "deep_guard")
            result = MCP.request(client, method, Dict())
            @test result isa MCP.Failure && result.kind == :protocol
            @test !occursin("synthetic-secret", string(result))
            @test MCP.request(client, "valid", Dict()) == Dict("scenario" => "valid")
        end
        failure = MCP.request(client, "valid_error", Dict())
        @test failure isa MCP.Failure && failure.kind == :rpc && failure.message == "request failed"
        if haskey(ENV, "PI_SOURCE")
            @test readchomp(`git -C $(ENV["PI_SOURCE"]) rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
            reference = wireoracle("http", url, scenarios)
            for method in errors
                @test reference[method]["failed"]
            end
            @test reference["valid"]["result"] == Dict("scenario" => "valid")
            @test reference["valid_error"]["error"]["code"] == -32001
        end
    finally
        close(client); close(server)
    end
end

@testset "Stdio JSON ignores malformed lines and delivers later replies" begin
    scenarios = ("trailing", "malformed", "control", "leading_zero", "bad_error", "null_error", "bad_version", "ambiguous", "nonobject", "blank", "foreign_id", "valid", "valid_error")
    errors = Set(("trailing", "malformed", "control", "leading_zero", "bad_error", "null_error", "bad_version", "ambiguous", "nonobject"))
    script = joinpath(@__DIR__, "mcp_wire_stdio_server.mjs")
    client = MCP.connect(`node $script`; timeout=15, grace=0.2)
    try
        @test client isa MCP.Client
        for method in (scenarios..., "deep_guard", "valid")
            result = MCP.request(client, method, Dict())
            if method == "valid_error"
                @test result isa MCP.Failure && result.kind == :rpc && result.message == "request failed"
            else
                @test result == Dict("scenario" => method)
            end
        end
        if haskey(ENV, "PI_SOURCE")
            reference = wireoracle("stdio", "", scenarios)
            for method in scenarios
                if method == "valid_error"
                    @test reference[method]["error"]["code"] == -32001
                else
                    @test reference[method]["result"] == Dict("scenario" => method)
                end
                @test reference[method]["errors"] == Int(method in errors)
            end
        end
    finally
        close(client)
    end
end
end
