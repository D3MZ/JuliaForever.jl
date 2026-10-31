module SkillResumeRaceTests

using Test, JuliaForever
const H = JuliaForever.History

struct Provider end
JuliaForever.complete(::Provider, messages, tools; kwargs...) = Dict{String, Any}("role" => "assistant", "content" => "ok")

mutable struct Store <: H.Store
    memory::H.Memory
    hook::Function
    closes::Int
end
H.snapshot(store::Store) = (store.hook(); H.snapshot(store.memory))
Base.append!(store::Store, revision::Integer, batch::Vector) = append!(store.memory, revision, batch)
Base.close(store::Store) = (store.closes += 1; nothing)

end
