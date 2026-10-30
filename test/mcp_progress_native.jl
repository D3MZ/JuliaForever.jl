using Test, JuliaForever
const MCP = JuliaForever.MCP
takebefore(channel) = timedwait(() -> isready(channel), 15) == :ok ? take!(channel) : error("timed out waiting for callback")
fetchbefore(task) = timedwait(() -> istaskdone(task), 15) == :ok ? fetch(task) : error("timed out waiting for request")
server() = `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) $(joinpath(@__DIR__, "mcp_progress_native_server.jl"))`

@testset "MCP progress lifecycle and bounded callbacks" begin
    client = MCP.connect(server(); timeout=20, grace=0.2)
    @test client isa MCP.Client
    try
        events = Any[]
        result = MCP.call(client, "echo", Dict("value" => 7); on_progress=event -> push!(events, event))
        @test result["structuredContent"]["params"]["_meta"]["progressToken"] == only(events)["progressToken"]
        @test only(events)["progress"] == 1
        params = Dict("_meta" => Dict("keep" => "yes", "progressToken" => "original"))
        MCP.request(client, "metadata", params; on_progress=identity)
        @test params == Dict("_meta" => Dict("keep" => "yes", "progressToken" => "original"))
        groups = [Any[] for _ in 1:16]
        jobs = [Threads.@spawn MCP.request(client, "concurrent", Dict("label" => index); on_progress=event -> begin
            push!(groups[index], event)
            MCP.request(client, "ack", Dict("label" => index))
        end) for index in 1:16]
        @test [result["label"] for result in fetch.(jobs)] == collect(1:16)
        @test [only(group)["progress"] for group in groups] == collect(1:16)
        @test length(unique(only(group)["progressToken"] for group in groups)) == 16

        nested = Channel{Any}(1)
        outer = MCP.request(client, "reentrant", Dict(); on_progress=event -> put!(nested, MCP.request(client, "nested", Dict())))
        @test outer == Dict("done" => true)
        @test take!(nested) == Dict("nested" => true)

        invalid = Any[]
        start = time()
        timeout = MCP.request(client, "invalid-timeout", Dict(); timeout=0.4, on_progress=event -> push!(invalid, event))
        @test timeout.kind == :timeout
        @test time() - start < 1.5
        @test isempty(invalid)

        entered = Channel{Nothing}(1)
        locked = Channel{Nothing}(1)
        releasewriter = Channel{Nothing}(1)
        job = @async MCP.request(client, "hold", Dict(); timeout=0.8, on_progress=event -> put!(entered, nothing))
        takebefore(entered)
        holder = @async lock(client.writer) do
            put!(locked, nothing)
            take!(releasewriter)
        end
        takebefore(locked)
        try
            @test fetchbefore(job).kind == :timeout
        finally
            put!(releasewriter, nothing)
        end
        fetchbefore(holder)
        MCP.request(client, "barrier", Dict())
        @test isempty(client.pending)

        entered = Channel{Nothing}(1)
        release = Channel{Nothing}(1)
        blocked = Any[]
        job = @async MCP.request(client, "blocked", Dict(); on_progress=event -> begin
            push!(blocked, event)
            put!(entered, nothing)
            take!(release)
        end)
        takebefore(entered)
        @test fetchbefore(job) == Dict("done" => true)
        put!(release, nothing)
        MCP.request(client, "barrier", Dict())
        @test [event["progress"] for event in blocked] == [1]

        entered = Channel{Nothing}(1)
        release = Channel{Nothing}(1)
        overflowevents = Any[]
        job = @async MCP.request(client, "overflow", Dict(); on_progress=event -> begin
            push!(overflowevents, event)
            put!(entered, nothing)
            take!(release)
        end)
        takebefore(entered)
        @test fetchbefore(job).kind == :progress
        put!(release, nothing)
        MCP.request(client, "barrier", Dict())
        @test [event["progress"] for event in overflowevents] == [1]
        @test isempty(client.pending)

        entered = Channel{Nothing}(1)
        cancelled = Any[]
        job = @async MCP.request(client, "hold", Dict(); on_progress=event -> begin
            push!(cancelled, event)
            put!(entered, nothing)
        end)
        takebefore(entered)
        schedule(job, InterruptException(); error=true)
        @test_throws TaskFailedException fetchbefore(job)
        MCP.request(client, "barrier", Dict())
        @test [event["progress"] for event in cancelled] == [1]
        @test isempty(client.pending)

        entered = Channel{Nothing}(1)
        release = Channel{Nothing}(1)
        timed = Any[]
        job = @async MCP.request(client, "hold", Dict(); timeout=0.3, on_progress=event -> begin
            push!(timed, event)
            put!(entered, nothing)
            take!(release)
        end)
        takebefore(entered)
        @test fetchbefore(job).kind == :timeout
        put!(release, nothing)
        MCP.request(client, "barrier", Dict())
        @test [event["progress"] for event in timed] == [1]
        @test isempty(client.pending)

        entered = Channel{Nothing}(1)
        release = Channel{Nothing}(1)
        closed = Any[]
        job = @async MCP.request(client, "hold", Dict(); on_progress=event -> begin
            push!(closed, event)
            put!(entered, nothing)
            take!(release)
        end)
        takebefore(entered)
        close(client)
        @test fetchbefore(job).kind == :closed
        put!(release, nothing)
        yield()
        @test [event["progress"] for event in closed] == [1]
        @test isempty(client.pending)
    finally
        close(client)
    end

    client = MCP.connect(server(); timeout=20, grace=0.2)
    try
        events = [Any[], Any[]]
        entered = Channel{Int}(2)
        hold = Threads.@spawn MCP.request(client, "hold", Dict(); on_progress=event -> begin
            push!(events[1], event)
            put!(entered, 1)
        end)
        @test takebefore(entered) == 1
        eof = Threads.@spawn MCP.request(client, "eof", Dict(); on_progress=event -> begin
            push!(events[2], event)
            put!(entered, 2)
        end)
        @test takebefore(entered) == 2
        @test all(result -> result.kind == :closed, fetchbefore.((hold, eof)))
        @test [[event["progress"] for event in group] for group in events] == [[1], [1]]
        @test isempty(client.pending)
    finally
        close(client)
    end
end
