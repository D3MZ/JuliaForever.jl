module FollowPlugin

using JuliaForever
const Extensions = JuliaForever.Extensions

struct Farewell <: JuliaForever.Tool end
JuliaForever.name(::Farewell) = get(ENV, "JF_TEST_FOLLOW", "") == "collision" ? "greet" : "farewell"
JuliaForever.description(::Farewell) = "Say farewell"
JuliaForever.schema(::Farewell) = Dict("type" => "object")
JuliaForever.execute(::Farewell, args) = ToolResult("Goodbye!")

function plugin()
    record = event -> open(ENV["JF_TEST_EVENTS"], "a") do io
        println(io, "follow:", event.type)
    end
    Extensions.Plugin(; tools=(Farewell(),), hooks=(:agent_start => record, :tool_execution_end => record, :agent_end => record))
end

end
