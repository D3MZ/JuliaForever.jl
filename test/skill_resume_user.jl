module SkillResumeUserTests

using Test, JuliaForever
const H = JuliaForever.History

struct Provider end
JuliaForever.complete(::Provider, messages, tools; kwargs...) = Dict{String, Any}("role" => "assistant", "content" => "answer")

end
