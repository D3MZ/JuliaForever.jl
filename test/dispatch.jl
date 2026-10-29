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
    @test typeof(success) !== typeof(failure)
    @test ToolResult("ok") == success
    @test ToolResult("ok", false) == success
    @test ToolResult("failed", true) == failure
    @test !success.iserror && failure.iserror
    @test JuliaForever.toolmessage(call, success) == Dict("role" => "tool", "tool_call_id" => "call", "content" => "ok")
    @test JuliaForever.toolmessage(call, failure) == Dict("role" => "tool", "tool_call_id" => "call", "content" => "Error: failed")

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

@testset "tool request dispatch" begin
    tool = CountingTool(Ref(0))
    agent = Agent(nothing, [tool])
    call = Dict("id" => "call", "function" => Dict("name" => "count", "arguments" => "{}"))
    request = JuliaForever.Conversation.ToolCall("call", "count", "{}")
    run = JuliaForever.Conversation.ToolRequest(request)
    skip = JuliaForever.Conversation.SkipRequest(request)
    events = []

    @test JuliaForever.toolresult(agent, call, run, event -> push!(events, event)) == ToolSuccess("ran")
    @test JuliaForever.toolresult(agent, call, skip, event -> push!(events, event)) isa ToolFailure
    @test tool.calls[] == 1
    @test JuliaForever.begin!(agent)
    @test hasproperty(agent, :cancelled)
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
