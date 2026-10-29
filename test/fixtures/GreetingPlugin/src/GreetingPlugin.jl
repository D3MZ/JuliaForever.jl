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

struct Broken end
Extensions.tools(::Broken) = error("contribution failure: synthetic-secret")

function plugin()
    mode = get(ENV, "JF_TEST_PLUGIN", "")
    mode == "factory" && error("factory failure: synthetic-secret")
    mode == "contribution" && return Broken()
    mode == "collision" && return Extensions.Plugin(; tools=(Read(pwd()),))
    record = event -> if haskey(ENV, "JF_TEST_EVENTS")
        open(ENV["JF_TEST_EVENTS"], "a") do io
            println(io, event.type)
        end
    end
    fail = event -> mode == "hook" && error("hook failure: synthetic-secret")
    Extensions.Plugin(; tools=(Greet(),), hooks=(:agent_start => fail, :agent_start => record, :tool_execution_end => record, :agent_end => record))
end

end
