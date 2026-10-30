using Test, JuliaForever, JSON3

const MCP = JuliaForever.MCP

@testset "MCP response conversion" begin
    failure = MCP.Failure(:rpc, "bad")
    @test MCP.toolresponse(failure) === failure
    @test MCP.toolresponse(Dict("content" => Any[])) == Dict("content" => Any[])
    @test MCP.toolresponse(Dict("content" => "bad")) isa MCP.Failure
    @test MCP.toolresponse(JSON3.read("{\"content\":[],\"isError\":false}")) isa AbstractDict
    @test MCP.toolresponse(Dict("structuredContent" => nothing)) == Dict("structuredContent" => nothing)
    for bad in (Dict(), Dict("content" => nothing), Dict("content" => missing, "structuredContent" => 1), Dict("content" => [], "isError" => nothing), Dict("content" => [], "isError" => 1))
        @test MCP.toolresponse(bad) isa MCP.Failure
    end
    @test MCP.cursorparams(nothing) == Dict()
    @test MCP.cursorparams("next") == Dict("cursor" => "next")
    blocks = Any[Dict("type" => "text", "text" => "ok"), Dict("type" => "text", "text" => 3), Dict("type" => "resource_link", "uri" => "file:///item"), false]
    result = MCP.toolresult(Dict("content" => blocks, "isError" => true))
    @test result isa ToolFailure
    @test result.text == join(["ok", JSON3.write(blocks[2]), JSON3.write(blocks[3]), JSON3.write(blocks[4])], "\n")
end

@testset "MCP connection admission" begin
    @test MCP.admit(MCP.Open(), MCP.Open())
    @test MCP.admit(MCP.Open(), MCP.Connecting())
    @test MCP.admit(MCP.Connecting(), MCP.Connecting())
    @test !MCP.admit(MCP.Connecting(), MCP.Open())
    @test !MCP.admit(MCP.Closed(), MCP.Connecting())
end

mutable struct MCPProvider
    requests::Vector{Any}
end

function JuliaForever.complete(provider::MCPProvider, messages, tools)
    push!(provider.requests, deepcopy(messages))
    if length(provider.requests) == 1
        call = Dict("id" => "mcp-call", "type" => "function", "function" => Dict("name" => "mcp_alpha", "arguments" => "{\"value\":42}"))
        return Dict("role" => "assistant", "content" => nothing, "tool_calls" => [call])
    end
    Dict("role" => "assistant", "content" => "done")
end

function mcpserver(mode, marker)
    `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) $(joinpath(@__DIR__, "mcp_server.jl")) $mode $marker`
end

@testset "MCP stdio" begin
    mktempdir() do dir
        marker = joinpath(dir, "started")
        client = MCP.connect(mcpserver("normal", marker); timeout=10, grace=0.2)
        @test client isa MCP.Client
        if client isa MCP.Client
            @test MCP.admission!(client, MCP.Closed(), MCP.Open()).kind == :closed
            @test MCP.activate!(client, MCP.Closed()) isa MCP.Failure
            @test client.connection isa MCP.Open
            @test MCP.send(client, Dict(), MCP.Closed()) isa MCP.Failure
            @test client.shutdown isa MCP.ShutdownReady
            @test !client.shutting
            @test client.state === :open
            @test client.connection isa MCP.Open
            @test client.server["serverInfo"]["name"] == "mock"
            @test client.server["capabilities"]["tools"]["listChanged"]
            tools = MCP.tools(client)
            @test tools isa Vector{MCP.RemoteTool}
            if tools isa Vector{MCP.RemoteTool}
                @test JuliaForever.name.(tools) == ["mcp_alpha", "mcp_second_test"]
                @test JuliaForever.description.(tools) == ["First", "second.test"]
                @test JuliaForever.schema(tools[1])["properties"]["value"]["type"] == "integer"
                @test execute(tools[1], (; value=7)).text == "alpha:7"
                @test execute(tools[2], (; value=8)).text == "second.test:8"
                @test execute(tools[1], (; value="line 1\nline 2")).text == "alpha:line 1\nline 2"
                @test Agent(nothing, tools).tools["mcp_alpha"] === tools[1]
                provider = MCPProvider([])
                agent = Agent(provider, tools)
                @test respond!(agent, "call alpha") == "done"
                @test provider.requests[2][end]["content"] == "alpha:42"
            end
            jobs = [Threads.@spawn MCP.call(client, "reverse", Dict("value" => i)) for i in 1:3]
            @test timedwait(() -> all(istaskdone, jobs), 10) == :ok
            if all(istaskdone, jobs)
                replies = fetch.(jobs)
                @test [r["content"][1]["text"] for r in replies] == string.(1:3)
            end
            failure = MCP.call(client, "protocol_error", Dict())
            @test failure isa MCP.Failure && failure.kind == :rpc && failure.data["code"] == -32602
            failure = MCP.call(client, "invalid_error", Dict())
            @test failure isa MCP.Failure && failure.kind == :protocol
            @test MCP.call(client, "invalid_result", Dict()) isa MCP.Failure
            failed = MCP.RemoteTool(client, "tool_error", "failed", "", Dict("type" => "object"))
            result = execute(failed, Dict())
            @test result.iserror && result.text == "tool failed"
            mixed = MCP.RemoteTool(client, "mixed", "mixed", "", Dict("type" => "object"))
            result = execute(mixed, Dict())
            @test !result.iserror && occursin("hello", result.text) && occursin("file:///item", result.text) && occursin("\"value\":3", result.text)
            timeout = MCP.call(client, "timeout", Dict(); timeout=0.2)
            @test timeout isa MCP.Failure && timeout.kind == :timeout
            @test MCP.call(client, "check_cancelled", Dict())["structuredContent"]["cancelled"]
            incoming = MCP.call(client, "check_requests", Dict())["structuredContent"]
            @test incoming["server-ping"]["result"] == Dict()
            @test incoming["server-unknown"]["error"]["code"] == -32601
            rm(marker; force=true)
            pending = Threads.@spawn MCP.call(client, "hold", Dict())
            @test timedwait(() -> isfile(marker), 5) == :ok
            closers = [Threads.@spawn close(client) for _ in 1:6]
            @test timedwait(() -> all(istaskdone, closers), 10) == :ok
            foreach(fetch, filter(istaskdone, closers))
            @test client.shutdown isa MCP.ShuttingDown
            @test client.shutting
            @test client.state === :closed
            @test client.connection isa MCP.Closed
            @test timedwait(() -> istaskdone(pending), 5) == :ok
            @test fetch(pending) isa MCP.Failure
            @test process_exited(client.process)
            @test istaskdone(client.reader)
            close(client)
            rejected = MCP.call(client, "alpha", Dict())
            @test rejected isa MCP.Failure && rejected.kind == :closed
        end
        @test MCP.connect(mcpserver("badversion", marker); timeout=10, grace=0.2) isa MCP.Failure
        @test MCP.connect(mcpserver("badcap", marker); timeout=10, grace=0.2) isa MCP.Failure
        for mode in ("badcaps", "badinfo", "badname", "badserverversion")
            failure = MCP.connect(mcpserver(mode, marker); timeout=10, grace=0.2)
            @test failure isa MCP.Failure && failure.kind == :protocol
        end
        for (mode, version) in (("oldversion", "2025-06-18"), ("oldversion2", "2025-03-26"), ("oldversion3", "2024-11-05"))
            older = MCP.connect(mcpserver(mode, marker); timeout=10, grace=0.2)
            @test older isa MCP.Client && older.server["protocolVersion"] == version
            older isa MCP.Client && close(older)
        end
        unavailable = MCP.connect(mcpserver("no_tools", marker); timeout=10, grace=0.2)
        @test unavailable isa MCP.Client
        if unavailable isa MCP.Client
            @test MCP.tools(unavailable) isa MCP.Failure
            @test MCP.call(unavailable, "alpha", Dict()) isa MCP.Failure
            close(unavailable)
        end
        collisions = MCP.connect(mcpserver("collisions", marker); timeout=10, grace=0.2)
        @test collisions isa MCP.Client
        if collisions isa MCP.Client
            @test MCP.tools(collisions) isa MCP.Failure
            close(collisions)
        end
        looping = MCP.connect(mcpserver("loopcursor", marker); timeout=10, grace=0.2)
        @test looping isa MCP.Client
        if looping isa MCP.Client
            @test MCP.tools(looping) isa MCP.Failure
            close(looping)
        end
        badcursor = MCP.connect(mcpserver("badcursor", marker); timeout=10, grace=0.2)
        @test badcursor isa MCP.Client
        if badcursor isa MCP.Client
            @test MCP.tools(badcursor) isa MCP.Failure
            close(badcursor)
        end
        required = MCP.connect(mcpserver("taskrequired", marker); timeout=10, grace=0.2)
        @test required isa MCP.Client
        if required isa MCP.Client
            failure = MCP.tools(required)
            @test failure isa MCP.Failure && failure.kind == :capability && occursin("long_task", failure.message)
            close(required)
        end
        for (mode, message) in (("badtools", "Invalid MCP tools/list result"), ("baddefinition", "Invalid MCP tool definition"), ("badschema", "Invalid MCP tool definition"), ("badexecution", "Invalid MCP tool execution metadata"), ("badsupport", "Invalid MCP task support"), ("badtypesupport", "Invalid MCP task support"), ("baddescription", "Invalid MCP tool description"))
            invalid = MCP.connect(mcpserver(mode, marker); timeout=10, grace=0.2)
            @test invalid isa MCP.Client
            if invalid isa MCP.Client
                failure = MCP.tools(invalid)
                @test failure isa MCP.Failure && failure.kind == :protocol && failure.message == message
                close(invalid)
            end
        end
        for mode in ("lasttoolpage", "limittools")
            paged = MCP.connect(mcpserver(mode, marker); timeout=10, grace=0.2)
            @test paged isa MCP.Client
            if paged isa MCP.Client
                result = MCP.tools(paged)
                if mode == "lasttoolpage"
                    @test result == MCP.RemoteTool[]
                else
                    @test result isa MCP.Failure && result.kind == :protocol && result.message == "MCP tools/list exceeded 1000 pages"
                end
                close(paged)
            end
        end
        incomplete = MCP.connect(mcpserver("incomplete", marker); timeout=10, grace=0.2)
        @test incomplete isa MCP.Client
        if incomplete isa MCP.Client
            failure = MCP.call(incomplete, "anything", Dict())
            @test failure isa MCP.Failure && failure.kind == :protocol
            close(incomplete)
        end
        eofclient = MCP.connect(mcpserver("eof", marker); timeout=10, grace=0.2)
        @test eofclient isa MCP.Client
        if eofclient isa MCP.Client
            jobs = [Threads.@spawn MCP.call(eofclient, "reverse", Dict("value" => i)) for i in 1:3]
            @test timedwait(() -> all(istaskdone, jobs), 10) == :ok
            @test all(x -> x isa MCP.Failure && x.kind == :closed, fetch.(jobs))
            close(eofclient)
            @test process_exited(eofclient.process)
            @test istaskdone(eofclient.reader)
        end
        broken = MCP.connect(mcpserver("malformed", marker); timeout=10, grace=0.2)
        @test broken isa MCP.Client
        if broken isa MCP.Client
            @test MCP.call(broken, "anything", Dict()) isa MCP.Failure
            close(broken)
            @test process_exited(broken.process)
        end
        if Sys.isunix()
            stubborn = MCP.connect(`sh $(joinpath(@__DIR__, "mcp_stubborn.sh"))`; timeout=10, grace=0.2)
            @test stubborn isa MCP.Client
            if stubborn isa MCP.Client
                started = time()
                close(stubborn)
                @test time() - started < 5
                @test process_exited(stubborn.process)
                @test stubborn.process.termsignal == Base.SIGKILL
            end
        end
        @test MCP.connect(`jf-nonexistent-mcp-server`; timeout=1, grace=0.1) isa MCP.Failure
    end
end
