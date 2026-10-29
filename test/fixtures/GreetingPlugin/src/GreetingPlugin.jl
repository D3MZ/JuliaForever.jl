module GreetingPlugin

using JuliaForever
const Extensions = JuliaForever.Extensions

struct Greet <: JuliaForever.Tool end
JuliaForever.name(::Greet) = "greet"
JuliaForever.description(::Greet) = "Greet a person"
JuliaForever.schema(::Greet) = Dict("type" => "object", "properties" => Dict("name" => Dict("type" => "string")), "required" => ["name"])
JuliaForever.execute(::Greet, args) = ToolResult("Hello, $(args.name)!")

struct Plugin
    events::Vector{Symbol}
end

Extensions.tools(::Plugin) = (Greet(),)
Extensions.hooks(plugin::Plugin) = (:agent_start => (event -> push!(plugin.events, event.type)), :tool_execution_end => (event -> push!(plugin.events, event.type)), :agent_end => (event -> push!(plugin.events, event.type)))

end
