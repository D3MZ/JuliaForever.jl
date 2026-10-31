using Test, JuliaForever
const H = JuliaForever.History

struct ParallelProvider end
JuliaForever.complete(::ParallelProvider, messages, tools; kwargs...) = Dict{String, Any}("role" => "assistant", "content" => "ok")

mutable struct BarrierStore <: H.Store
    memory::H.Memory
    reached::Threads.Atomic{Int}
    release::Channel{Nothing}
    enabled::Bool
end
H.snapshot(store::BarrierStore) = H.snapshot(store.memory)
function Base.append!(store::BarrierStore, revision::Integer, batch::Vector)
    if store.enabled
        Threads.atomic_add!(store.reached, 1)
        take!(store.release)
    end
    append!(store.memory, revision, batch)
end
Base.close(::BarrierStore) = nothing
