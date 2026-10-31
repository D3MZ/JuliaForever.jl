using Test, JuliaForever, JSON3
import JuliaForever.History as H
import JuliaForever.Durable as D
import JuliaForever.Conversation as C
import JuliaForever.Kernel as K

struct FailHistory{T} <: H.Store
    store::H.Memory
end
FailHistory(store::H.Memory, ::Type{T}) where T = FailHistory{T}(store)
H.snapshot(history::FailHistory) = H.snapshot(history.store)
function H.append!(history::FailHistory{T}, revision::Integer, batch::Vector) where T
    H.decode_event(only(batch)) isa T && return H.Rejected(:failed)
    H.append!(history.store, revision, batch)
end

struct UncertainHistory <: H.Store
    store::H.Memory
end
H.snapshot(history::UncertainHistory) = H.snapshot(history.store)
function H.append!(history::UncertainHistory, revision::Integer, batch::Vector)
    result = H.append!(history.store, revision, batch)
    revision == 0 && return result
    error("connection lost after append")
end

mutable struct KeyedProvider
    key::String
    calls::Int
end
function JuliaForever.complete(provider::KeyedProvider, messages, tools)
    provider.calls += 1
    Dict{String, Any}("role" => "assistant", "content" => "done")
end

struct BrokenHistoryProvider end
JuliaForever.complete(::BrokenHistoryProvider, messages, tools) = error("provider disconnected")
