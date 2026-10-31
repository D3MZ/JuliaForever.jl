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
