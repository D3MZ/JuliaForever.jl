using Test, JuliaForever, JSON3, Logging

const ProgressMCP = JuliaForever.MCP
progressserver() = `node $(joinpath(@__DIR__, "mcp_progress_server.mjs"))`

function progresscomparison()
    client = ProgressMCP.connect(progressserver(); timeout=20, grace=0.2)
    @test client isa ProgressMCP.Client
    probeevents = Any[]
    try
        probe = ProgressMCP.request(client, "probe", Dict("_meta" => Dict("preserved" => "yes", "progressToken" => "replace")); on_progress=event -> push!(probeevents, event))
        plain = ProgressMCP.request(client, "plain", Dict("value" => 1))
        pairedevents = [Any[], Any[]]
        jobs = [@async ProgressMCP.request(client, "pair", Dict("label" => label); on_progress=event -> push!(pairedevents[label], event)) for label in 1:2]
        pair = fetch.(jobs)
        slowevents = Any[]
        slow = ProgressMCP.request(client, "slow", Dict(); timeout=1.0, on_progress=event -> push!(slowevents, event))
        throwevents = Any[]
        thrown = ProgressMCP.request(client, "throw", Dict(); on_progress=event -> begin
            push!(throwevents, event)
            event["progress"] == 1 && error("callback failed")
        end)
        rpcevents = Any[]
        rpc = ProgressMCP.request(client, "rpc", Dict(); on_progress=event -> push!(rpcevents, event))
        ProgressMCP.request(client, "barrier", Dict())
        timeoutevents = Any[]
        timeout = ProgressMCP.request(client, "timeout", Dict(); timeout=0.35, on_progress=event -> push!(timeoutevents, event))
        ProgressMCP.request(client, "barrier", Dict())
        notimeout = [ProgressMCP.request(client, "no-timeout", Dict(); timeout=value) for value in (0.0, -1.0, Inf)]
        metadata = [ProgressMCP.request(client, "metadata", params; on_progress=identity) for params in (nothing, Dict("_meta" => "invalid"), (; _meta=(; keep="yes")))]
        (; probe, probeevents, plain, pair, pairedevents, slow, slowevents, thrown, throwevents, rpc, rpcevents, timeout, timeoutevents, notimeout, metadata)
    finally
        close(client)
    end
end

@testset "MCP progress compared to pinned Pi" begin
    @test readchomp(`git -C $(ENV["PI_SOURCE"]) rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    oracle = JSON3.read(read(addenv(`node $(joinpath(@__DIR__, "mcp_progress_oracle.mjs"))`, "JF_PROJECT" => dirname(@__DIR__)), String), Dict{String, Any})
    logger = Test.TestLogger(min_level=Logging.Warn)
    actual = with_logger(progresscomparison, logger)
    @test any(record -> record.level == Logging.Warn && record.message == "MCP progress callback failed", logger.logs)
    @test actual.probe == oracle["probe"]
    @test actual.probeevents == oracle["probeEvents"]
    @test actual.plain == oracle["plain"]
    @test actual.pair == oracle["pair"]
    @test actual.pairedevents == oracle["pairedEvents"]
    @test actual.slow == oracle["slow"]
    @test actual.slowevents == oracle["slowEvents"]
    @test actual.thrown == oracle["thrown"]
    @test actual.throwevents == oracle["throwEvents"]
    @test oracle["seenErrors"] == ["callback failed"]
    @test actual.rpc.kind == :rpc && actual.rpc.data["code"] == oracle["rpcCode"]
    @test actual.rpcevents == oracle["rpcEvents"]
    @test actual.timeout.kind == :timeout && oracle["timeoutName"] == "McpTimeoutError"
    @test actual.timeoutevents == oracle["timeoutEvents"]
    @test actual.notimeout == oracle["noTimeout"]
    @test actual.metadata == oracle["metadata"]
end
