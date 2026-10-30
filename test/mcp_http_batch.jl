using Test, HTTP, JSON3, JuliaForever
const MCP = JuliaForever.MCP

@testset "MCP HTTP JSON arrays" begin
    methods = ("batch", "notice_batch", "error_batch", "valid_first", "invalid_first", "invalid_item", "nested_item", "empty", "bad_json", "object")
    ids, release = Channel{Int}(2), Channel{Nothing}(2)
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do req
        req.method == "GET" && return HTTP.Response(405)
        req.method == "DELETE" && return HTTP.Response(204)
        body = JSON3.read(String(req.body), Dict{String, Any})
        haskey(body, "id") || return HTTP.Response(202)
        method, id = body["method"], body["id"]
        result = method == "initialize" ? Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict(), "serverInfo" => Dict("name" => "fixture", "version" => "1")) : Dict("scenario" => method)
        good = Dict("jsonrpc" => "2.0", "id" => id, "result" => result)
        if method == "first"
            put!(ids, id)
            take!(release)
        end
        bad = Dict("jsonrpc" => "1.0", "id" => id, "result" => "incorrect")
        response = if method == "batch"
            [good]
        elseif method == "notice_batch"
            [Dict("jsonrpc" => "2.0", "method" => "fixture/notice", "params" => Dict()), good]
        elseif method == "error_batch"
            [Dict("jsonrpc" => "2.0", "id" => id, "error" => Dict("code" => -32001, "message" => "request failed"))]
        elseif method == "valid_first"
            [good, bad]
        elseif method == "invalid_first"
            [bad, good]
        elseif method == "invalid_item"
            [nothing, good]
        elseif method == "nested_item"
            [[], good]
        elseif method == "multiple"
            [Dict("jsonrpc" => "2.0", "id" => take!(ids), "result" => Dict("scenario" => "first")), good]
        elseif method == "empty"
            []
        else
            good
        end
        encoded = JSON3.write(response) * (method == "bad_json" ? " trailing" : "")
        HTTP.Response(200, ["Content-Type" => "application/json"], encoded)
    end
    url = "http://$(HTTP.server_addr(server))/mcp"
    client = MCP.connect(url; timeout=15)
    try
        for method in methods
            result = MCP.request(client, method, Dict(); timeout=1.2)
            if method in ("batch", "notice_batch", "valid_first", "object")
                @test result == Dict("scenario" => method)
            elseif method == "error_batch"
                @test result isa MCP.Failure && result.kind == :rpc && result.message == "request failed"
            elseif method == "empty"
                @test result isa MCP.Failure && result.kind == :timeout
            else
                @test result isa MCP.Failure && result.kind == :protocol
            end
        end
        first = @async MCP.request(client, "first", Dict(); timeout=10)
        @test timedwait(() -> isready(ids), 5) == :ok
        second = @async MCP.request(client, "multiple", Dict(); timeout=10)
        @test fetch(first) == Dict("scenario" => "first")
        @test fetch(second) == Dict("scenario" => "multiple")
        put!(release, nothing)
        if haskey(ENV, "PI_SOURCE")
            @test readchomp(`git -C $(ENV["PI_SOURCE"]) rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
            script = joinpath(@__DIR__, "mcp_http_batch_pi.mjs")
            env = Dict("PI_SOURCE" => ENV["PI_SOURCE"], "JF_HTTP_URL" => url)
            task = @async read(addenv(`node $script $methods concurrent`, env), String)
            @test timedwait(() -> istaskdone(task), 20) == :ok
            reference = JSON3.read(fetch(task), Dict{String, Any})
            for method in ("batch", "notice_batch", "valid_first", "object")
                @test reference[method]["result"] == Dict("scenario" => method)
            end
            @test reference["error_batch"]["message"] == "request failed"
            @test reference["empty"]["error"] == "McpTimeoutError"
            for method in ("invalid_first", "invalid_item", "nested_item", "bad_json")
                @test haskey(reference[method], "error")
            end
            @test reference["concurrent"]["results"] == [Dict("scenario" => "first"), Dict("scenario" => "multiple")]
            put!(release, nothing)
        end
    finally
        put!(release, nothing)
        close(client)
        close(server)
    end
end
