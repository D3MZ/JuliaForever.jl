using Distributed

struct FaultTool <: JuliaForever.Tool
    calls::Base.RefValue{Int}
end

FaultTool() = FaultTool(Ref(0))

JuliaForever.name(::FaultTool) = "fault"
JuliaForever.description(::FaultTool) = "Test tool with a programming error"
JuliaForever.schema(::FaultTool) = Dict("type" => "object")
fault() = 1 + "unexpected"
function JuliaForever.execute(tool::FaultTool, args)
    tool.calls[] += 1
    fault()
end

struct InvalidReturnTool <: JuliaForever.Tool end
JuliaForever.name(::InvalidReturnTool) = "invalid_return"
JuliaForever.description(::InvalidReturnTool) = "Test tool with an invalid result"
JuliaForever.schema(::InvalidReturnTool) = Dict("type" => "object")
JuliaForever.execute(::InvalidReturnTool, args) = 1

struct ContextTool <: JuliaForever.Tool
    caller::Task
end
JuliaForever.name(::ContextTool) = "context"
function JuliaForever.execute(tool::ContextTool, args)
    value = task_local_storage(:tool_context)
    task_local_storage(:tool_context, value + 1)
    ToolResult(string(value, ":", current_task() === tool.caller))
end

@testset "tool failures and programming errors" begin
    mktempdir() do dir
        @test_throws SystemError execute(Read(dir), (; path="absent.txt"))
        missing = call("missing", "read", (; path="absent.txt"))
        provider = AgentFixture([completion(nothing; calls=[missing], finish="tool_calls"), completion("recovered")], [])
        agent = Agent(provider, [Read(dir)])
        @test respond!(agent, "read") == "recovered"
        @test occursin("absent.txt", last(provider.requests[2])["content"])
        try
            read(joinpath(dir, "absent.txt"), String)
        catch
            @test JuliaForever.attempt(() -> ToolSuccess("ok")).text == "ok"
            @test_throws MethodError JuliaForever.attempt(fault)
            failure = JuliaForever.attempt(() -> read(joinpath(dir, "absent.txt"), String))
            @test failure isa ToolFailure && occursin("absent.txt", failure.text)
        end
        chained() = try
            read(joinpath(dir, "absent.txt"), String)
        catch
            fault()
        end
        @test_throws MethodError JuliaForever.attempt(chained)

        broken = call("broken", "fault", (;))
        provider = AgentFixture([completion(nothing; calls=[broken], finish="tool_calls"), completion("should not continue")], [])
        tool = FaultTool()
        agent = Agent(provider, [tool])
        exception, trace = try
            respond!(agent, "run"; tool_execution=:sequential), nothing
        catch exception
            exception, catch_backtrace()
        end
        @test exception isa MethodError
        if exception isa Exception
            diagnostic = sprint(showerror, exception, trace)
            @test occursin("MethodError", diagnostic)
            @test occursin("fault", diagnostic)
        end
        @test length(provider.requests) == 1
        @test tool.calls[] == 1
        @test !any(message -> message["role"] == "tool", agent.messages)

        task_local_storage(:tool_context, 41) do
            request = call("context", "context", (;))
            provider = AgentFixture([completion(nothing; calls=[request], finish="tool_calls"), completion("done")], [])
            @test respond!(Agent(provider, [ContextTool(current_task())]), "context"; tool_execution=:sequential) == "done"
            @test last(provider.requests[2])["content"] == "41:true"
            @test task_local_storage(:tool_context) == 42
        end

        execution = JuliaForever.Execution
        conversation = JuliaForever.Conversation
        context = "tool-fault-test"
        @test execution.install!(context, nothing, [FaultTool(), Read(dir)])
        pool = execution.Executor(myid())
        try
            request = conversation.ToolRequest(conversation.ToolCall("broken", "fault", "{}"))
            result = fetch(execution.submit!(pool, "broken", 1, execution.Work(context, request)))
            @test result isa execution.Failed
            if result isa execution.Failed
                @test occursin("MethodError", result.message)
                @test occursin("fault", result.message)
            end
            request = conversation.ToolRequest(conversation.ToolCall("missing", "read", "{\"path\":\"absent.txt\"}"))
            result = fetch(execution.submit!(pool, "missing", 1, execution.Work(context, request)))
            @test result isa execution.Completed
            @test result.value.iserror && occursin("absent.txt", result.value.text)
        finally
            close(pool)
            execution.uninstall!(context)
        end

        result = codeexecute(CodeMode([FaultTool()]; timeout=30), "tools.fault((;))")
        @test !result.ok
        @test result.kind == :worker
        @test occursin("MethodError", result.message)
        @test occursin("fault", result.message)
        @test only(result.calls).status == :error

        result = codeexecute(CodeMode([InvalidReturnTool()]; timeout=30), "tools.invalid_return((;))")
        @test !result.ok && result.kind == :worker
        @test occursin("image", result.message)
        @test only(result.calls).status == :error

        result = codeexecute(CodeMode([Read(dir)]; timeout=30), "tools.read((; path=\"absent.txt\"))")
        @test result.ok && result.value.iserror
        @test occursin("absent.txt", result.value.text)
    end
end
