using Test, JuliaForever

struct SkillReloadProvider end
JuliaForever.complete(::SkillReloadProvider, messages, tools; kwargs...) = Dict{String, Any}("role" => "assistant", "content" => "answer")

function reloadskill(path, description)
    mkpath(dirname(path))
    write(path, "---\nname: example\ndescription: $description\n---\nprivate content\n")
end

mutable struct FailingReloadHistory <: JuliaForever.History.Store
    memory::JuliaForever.History.Memory
    fail::Bool
end
JuliaForever.History.snapshot(store::FailingReloadHistory) = JuliaForever.History.snapshot(store.memory)
function JuliaForever.History.append!(store::FailingReloadHistory, revision::Integer, batch::Vector)
    store.fail && throw(SystemError("synthetic-secret", Int32(5)))
    JuliaForever.History.append!(store.memory, revision, batch)
end
