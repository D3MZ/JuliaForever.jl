using Test, JuliaForever

struct CountingTool <: JuliaForever.Tool
    calls::Base.RefValue{Int}
end
JuliaForever.name(::CountingTool) = "count"
function JuliaForever.execute(tool::CountingTool, args)
    tool.calls[] += 1
    ToolSuccess("ran")
end

@testset "tool result dispatch" begin
    success = ToolSuccess("ok")
    failure = ToolFailure("failed")
    call = Dict("id" => "call")

    @test success isa ToolResult
    @test failure isa ToolResult
    @test ToolResult("ok") == success
    @test ToolResult("ok", false) == success
    @test ToolResult("failed", true) == failure
    @test !success.iserror && failure.iserror
    @test JuliaForever.toolmessage(call, success) == Dict("role" => "tool", "tool_call_id" => "call", "content" => "ok", "is_error" => false)
    @test JuliaForever.toolmessage(call, failure) == Dict("role" => "tool", "tool_call_id" => "call", "content" => "Error: failed", "is_error" => true)

    for result in (success, failure)
        reply = JuliaForever.Conversation.ToolReply(result)
        @test reply.text == result.text
        @test reply.iserror == result.iserror
        event = JuliaForever.Kernel.Observe(0, "call", reply)
        encoded = JuliaForever.History.encode(event)
        @test isequal(JuliaForever.History.encode(JuliaForever.History.decode_event(encoded)), encoded)
    end

    request = JuliaForever.Conversation.ToolCall("call", "tool", "{}")
    @test JuliaForever.Conversation.ToolMessage(request, JuliaForever.Conversation.ToolReply(failure)).content == "Error: failed"
    @test JuliaForever.Conversation.ToolMessage(request, JuliaForever.Conversation.Abandoned("unknown"), "inspected").content == "Error: Tool outcome unknown; abandoned: inspected"
end

@testset "completion finish dispatch" begin
    message = Dict{String, Any}("role" => "assistant", "content" => "partial")
    truncated = Completion(message, nothing, "length", true, nothing)
    complete = Completion(message, nothing, "stop", true, nothing)
    @test JuliaForever.finish(message, truncated, JuliaForever.Truncated) isa JuliaForever.Truncated
    @test JuliaForever.finish(message, truncated) isa JuliaForever.Truncated
    @test JuliaForever.finish(message, complete) == "partial"
end

@testset "tool request dispatch" begin
    tool = CountingTool(Ref(0))
    agent = Agent(nothing, [tool])
    call = Dict("id" => "call", "function" => Dict("name" => "count", "arguments" => "{}"))
    request = JuliaForever.Conversation.ToolCall("call", "count", "{}")
    run = JuliaForever.Conversation.ToolRequest(request)
    skip = JuliaForever.Conversation.SkipRequest(request)
    @test JuliaForever.toolmode(JuliaForever.Parallel(), run) isa JuliaForever.Parallel
    @test JuliaForever.toolmode(JuliaForever.Parallel(), skip) isa JuliaForever.Sequential
    @test JuliaForever.toolmode(JuliaForever.Sequential(), run) isa JuliaForever.Sequential
    @test JuliaForever.batchmode([(effect=run,), (effect=run,)]) isa JuliaForever.Parallel
    @test JuliaForever.batchmode([(effect=run,), (effect=skip,), (effect=run,)]) isa JuliaForever.Sequential
    events = []

    @test JuliaForever.toolresult(agent, call, run, event -> push!(events, event)) == ToolSuccess("ran")
    @test JuliaForever.toolresult(agent, call, skip, event -> push!(events, event)) isa ToolFailure
    @test tool.calls[] == 1
    @test JuliaForever.begin!(agent)
    @test !agent.cancelled
    @test cancel!(agent)
    @test agent.cancelled
    @test JuliaForever.toolresult(agent, call, run, event -> push!(events, event)) == ToolFailure("Operation cancelled")
    @test JuliaForever.toolresult(agent, call, skip, event -> push!(events, event)) == ToolFailure("Operation cancelled")
    @test tool.calls[] == 1
    @test [event.iserror for event in events] == [false, true, true, true]
    JuliaForever.finish!(agent)
    @test !agent.cancelled
end

@testset "execution routing" begin
    agent = Agent(nothing, [])
    @test respond!(agent, "prompt"; executor=1) == JuliaForever.Execution.Rejected(:executor)
    @test respond!(agent, "prompt"; context="worker") == JuliaForever.Execution.Rejected(:executor)
    @test isempty(agent.events)
end

@testset "agent lifecycle states" begin
    agent = Agent(nothing, [])
    @test !agent.running && !agent.cancelled
    @test JuliaForever.startturn!(agent) isa JuliaForever.Running
    @test JuliaForever.startturn!(agent) === nothing
    @test respond!(agent, "overlap") == :busy
    executor = JuliaForever.Execution.Executor(1)
    try
        @test respond!(agent, "overlap"; executor, context="unused") == :busy
    finally
        close(executor)
    end
    JuliaForever.finish!(agent)
    recorded = Agent(nothing, []; history=JuliaForever.History.Memory())
    @test JuliaForever.startturn!(recorded) isa JuliaForever.Running
    @test respond!(recorded, "overlap") == :busy
    JuliaForever.finish!(recorded)
    @test JuliaForever.begin!(agent)
    @test agent.running && !agent.cancelled
    @test !JuliaForever.begin!(agent)
    @test cancel!(agent)
    @test agent.running && agent.cancelled
    @test cancel!(agent)
    @test !JuliaForever.begin!(agent)
    JuliaForever.finish!(agent)
    @test !agent.running && !agent.cancelled
    @test !cancel!(agent)
end

@testset "executor tool outcomes" begin
    E = JuliaForever.Execution
    reply = JuliaForever.Conversation.ToolReply(ToolSuccess("ok"))
    completed = E.Completed("id", 1, 1, reply)
    @test JuliaForever.toolreply(completed, JuliaForever.Running()) === reply
    @test JuliaForever.toolreply(E.Completed("id", 1, 1, "wrong"), JuliaForever.Running()) == E.Rejected(:unexpected_result)
    cancelled = E.Cancelled("id", 1, 1)
    @test JuliaForever.toolreply(cancelled, JuliaForever.Running()) === cancelled
    @test JuliaForever.toolreply(cancelled, JuliaForever.Cancelled()).text == "Operation cancelled"
    failed = E.Failed("id", 1, 1, "worker")
    @test JuliaForever.toolreply(failed, JuliaForever.Running()) === failed
end

@testset "code execution outcomes" begin
    success = CodeResult(true, 3, String[], NamedTuple[], Dict{String, Any}(), nothing, "", "", "", 1)
    failure = CodeResult(false, nothing, String[], NamedTuple[], Dict{String, Any}(), :script, "bad", "", "", 1)
    @test success isa JuliaForever.CodeSuccess && success.ok
    @test failure isa JuliaForever.CodeFailure && !failure.ok
end
