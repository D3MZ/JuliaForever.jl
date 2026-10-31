module ExtensionCases

using Test, JuliaForever, JSON3
const E = JuliaForever.Extensions

mktempdir() do dir
    mkpath(joinpath(dir, "JuliaForever"))
    cp(joinpath(@__DIR__, "..", "Project.toml"), joinpath(dir, "JuliaForever", "Project.toml"))
    cp(joinpath(@__DIR__, "..", "src"), joinpath(dir, "JuliaForever", "src"))
    cp(joinpath(@__DIR__, "fixtures", "GreetingPlugin"), joinpath(dir, "GreetingPlugin"))
    pushfirst!(LOAD_PATH, dir)
    try
        @eval using GreetingPlugin
    finally
        popfirst!(LOAD_PATH)
    end
end

mutable struct Provider
    replies::Vector{Any}
    requests::Vector{Any}
end

function JuliaForever.complete(provider::Provider, messages, tools)
    push!(provider.requests, (; messages=deepcopy(messages), tools=Dict(name => JuliaForever.definition(tool) for (name, tool) in tools)))
    popfirst!(provider.replies)
end

struct Broken end
E.tools(::Broken) = (Write(pwd()),)
E.hooks(::Broken) = error("failed while building plugin")

function provider()
    call = Dict("id" => "one", "type" => "function", "function" => Dict("name" => "greet", "arguments" => JSON3.write((; name="Ada"))))
    Provider([Dict("role" => "assistant", "content" => nothing, "tool_calls" => [call]), Dict("role" => "assistant", "content" => "done")], [])
end

end
