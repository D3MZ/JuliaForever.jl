using Test, JuliaForever, JSON3
const MCP = JuliaForever.MCP

@testset "MCP drains replies after stdin closes" begin
    mktempdir() do dir
        holdfile, readyfile = joinpath.((dir,), ("hold", "ready"))
        server = `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) $(joinpath(@__DIR__, "mcp_write_race_server.jl")) $holdfile $readyfile`
        client = MCP.connect(server; timeout=10, grace=0.2)
        try
            hold = @async MCP.request(client, "hold", Dict())
            @test timedwait(() -> isfile(holdfile), 15) == :ok
            missing = @async MCP.request(client, "hold", Dict())
            @test timedwait(() -> lock(() -> length(client.pending) == 2, client.lock), 15) == :ok
            # Queue a writer before the reader must answer the server's ping.
            lock(client.writer)
            probe = @async MCP.request(client, "probe", Dict())
            yield()
            println(client.process, "{\"jsonrpc\":\"2.0\",\"method\":\"release\"}")
            flush(client.process)
            @test timedwait(() -> isfile(readyfile), 15) == :ok
            @test timedwait(() -> process_exited(client.process), 15) == :ok
            @test MCP.send(client, Dict("jsonrpc" => "2.0", "method" => "probe")) isa MCP.Failure
            unlock(client.writer)
            @test timedwait(() -> istaskdone(hold) && istaskdone(missing) && istaskdone(probe), 15) == :ok
            @test fetch(hold) == Dict("done" => true)
            @test fetch(missing).kind == :closed
            @test fetch(probe).kind in (:closed, :transport)
        finally
            islocked(client.writer) && unlock(client.writer)
            close(client)
        end
    end
end

if haskey(ENV, "PI_SOURCE")
    @testset "Pi MCP failed write while stdout remains open" begin
        source = ENV["PI_SOURCE"]
        @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
        for timeout in ("zero", "inf")
            mktempdir() do dir
                holdfile, readyfile, stopfile = joinpath.((dir,), ("hold", "ready", "stop"))
                script = joinpath(@__DIR__, "mcp_write_race_pi.mjs")
                project = dirname(Base.active_project())
                reference = JSON3.read(read(`node $script $source $(first(Base.julia_cmd().exec)) $project $holdfile $readyfile $stopfile $timeout`, String), Dict{String, Any})
                @test reference["outcome"] == "failed"
                @test reference["buffered"] == Dict("result" => Dict("done" => true))
                @test reference["waiting"] == "pending" && reference["closed"] == Dict("failed" => true)
            end
        end
    end
end

@testset "MCP failed write while stdout remains open" begin
    for timeout in (0.0, Inf)
        mktempdir() do dir
            holdfile, readyfile, stopfile = joinpath.((dir,), ("hold", "ready", "stop"))
            server = `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) $(joinpath(@__DIR__, "mcp_write_race_server.jl")) $holdfile $readyfile $stopfile`
            client = MCP.connect(server; timeout=10, grace=0.2)
            held = false
            try
                hold = @async MCP.request(client, "hold", Dict(); timeout=Inf)
                @test timedwait(() -> isfile(holdfile), 15) == :ok
                missing = @async MCP.request(client, "hold", Dict(); timeout=Inf)
                @test timedwait(() -> lock(() -> length(client.pending) == 2, client.lock), 15) == :ok
                lock(client.writer)
                held = true
                callback = timeout == 0 ? nothing : identity
                probe = @async MCP.request(client, "probe", Dict(); timeout, on_progress=callback)
                @test timedwait(() -> lock(() -> length(client.pending) == 3, client.lock), 15) == :ok
                println(client.process, "{\"jsonrpc\":\"2.0\",\"method\":\"release\"}")
                flush(client.process)
                @test timedwait(() -> isfile(readyfile), 15) == :ok
                @test !process_exited(client.process)
                unlock(client.writer)
                held = false
                @test MCP.send(client, Dict("jsonrpc" => "2.0", "method" => "probe")) isa MCP.Failure
                completed = timedwait(() -> istaskdone(probe) && istaskdone(hold), 3)
                @test completed == :ok
                if completed == :ok
                    @test fetch(probe).kind == :transport
                    @test fetch(hold) == Dict("done" => true)
                    @test !istaskdone(missing)
                end
                write(stopfile, "stop")
                @test timedwait(() -> istaskdone(probe) && istaskdone(hold) && istaskdone(missing), 15) == :ok
                @test fetch(hold) == Dict("done" => true)
                @test fetch(missing).kind == :closed
            finally
                held && unlock(client.writer)
                write(stopfile, "stop")
                close(client)
            end
        end
    end
end
