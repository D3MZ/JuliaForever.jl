using Test, JuliaForever

struct CountingTool <: JuliaForever.Tool
    calls::Base.RefValue{Int}
end
JuliaForever.name(::CountingTool) = "count"
function JuliaForever.execute(tool::CountingTool, args)
    tool.calls[] += 1
    ToolSuccess("ran")
end
