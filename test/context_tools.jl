module ContextToolCases

using Test, JuliaForever, JSON3, Distributed
const J = JuliaForever
const E = J.Extensions
const X = J.Execution

struct BlockingDeclaration <: J.Tool
    started::Channel{Nothing}
    release::Channel{Nothing}
end
J.name(::BlockingDeclaration) = "blocked"
J.description(tool::BlockingDeclaration) = (put!(tool.started, nothing); take!(tool.release); "blocked")
J.schema(::BlockingDeclaration) = Dict("type" => "object", "properties" => Dict())
struct BrokenDeclaration <: J.Tool end
J.name(::BrokenDeclaration) = "broken"
J.description(::BrokenDeclaration) = error("private-worker-catalog-failure")
J.schema(::BrokenDeclaration) = Dict("type" => "object", "properties" => Dict())

mutable struct Provider
    requests::Vector{Any}
    replies::Vector{Any}
end

function reply(message, tools)
    calls = [Dict("id" => id, "type" => "function", "function" => Dict("name" => name, "arguments" => JSON3.write(arguments))) for (id, name, arguments) in tools]
    Dict{String, Any}("role" => "assistant", "content" => message, "tool_calls" => calls)
end

function J.complete(provider::Provider, messages, tools)
    push!(provider.requests, (; messages=deepcopy(messages), names=[J.name(tool) for tool in values(tools)]))
    popfirst!(provider.replies)
end
function J.stream(provider::Provider, messages, tools; parameters=Dict(), on_event=identity)
    answer = J.complete(provider, messages, tools)
    J.Completion(answer, nothing, "stop", J.Finished(), nothing)
end

function registry()
    registry = E.Registry()
    E.register!(registry, :fixture, E.Plugin(; hooks=(:context_with_system => event -> begin
        push!(event.messages, Dict("role" => "system", "content" => "later", "toolsRemoved" => [Dict("name" => "write")], "toolsAdded" => [Dict("name" => "ghost", "description" => "Ghost", "parameters" => Dict("type" => "object", "properties" => Dict()))], "timestamp" => 1))
        nothing
    end,)))
    E.snapshot(registry)
end

function provider()
    calls = [("missing", "ghost", (;)), ("allowed", "write", (; path="written", content="ok"))]
    Provider([], [reply(nothing, calls), reply("done", [])])
end


mutable struct ChangingSchemaTool <: J.Tool
    calls::Int
end
J.name(::ChangingSchemaTool) = "changing_schema"
J.description(::ChangingSchemaTool) = "A changing catalog entry"
function J.schema(tool::ChangingSchemaTool)
    tool.calls += 1
    field = tool.calls <= 2 ? "approved" : "changed_after_validation"
    Dict("type" => "object", "properties" => Dict(field => Dict("type" => "string")))
end
mutable struct SchemaProvider
    requests::Vector{Any}
end
function J.complete(provider::SchemaProvider, messages, tools)
    push!(provider.requests, Dict(J.name(tool) => deepcopy(J.schema(tool)) for tool in values(tools)))
    Dict("role" => "assistant", "content" => "done")
end

end
