using Test, JuliaForever

struct ResumeSkillProvider end
JuliaForever.complete(::ResumeSkillProvider, messages, tools; kwargs...) = Dict{String, Any}("role" => "assistant", "content" => "answer")
struct ResumeSkillCapture
    requests::Vector{Any}
end
function JuliaForever.stream(provider::ResumeSkillCapture, messages, tools; kwargs...)
    push!(provider.requests, deepcopy(messages))
    Completion(Dict{String, Any}("role" => "assistant", "content" => "answer"), nothing, "stop", true, nothing)
end
