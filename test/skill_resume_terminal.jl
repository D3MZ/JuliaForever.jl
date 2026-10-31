module SkillResumeTerminalTests

using Test, JuliaForever

struct Provider
    requests::Vector{Any}
end
JuliaForever.complete(::Provider, messages, tools; kwargs...) = Dict{String, Any}("role" => "assistant", "content" => "answer")
function JuliaForever.stream(provider::Provider, messages, tools; kwargs...)
    push!(provider.requests, deepcopy(messages))
    Completion(Dict{String, Any}("role" => "assistant", "content" => "answer"), nothing, "stop", true, nothing)
end

function skill(root, name)
    path = joinpath(root, ".pi", "skills", name, "SKILL.md")
    mkpath(dirname(path))
    write(path, "---\nname: $name\ndescription: $name metadata\n---\nprivate $name instructions\n")
    path
end

end
