using Test, JSON3, JuliaForever

import JuliaForever.Logs as L

mutable struct OnceHistory{T}
    items::T
    started::Bool
end

Base.IteratorSize(::Type{<:OnceHistory}) = Base.SizeUnknown()
Base.IteratorEltype(::Type{<:OnceHistory}) = Base.EltypeUnknown()
function Base.iterate(history::OnceHistory)
    history.started && error("history was iterated more than once")
    history.started = true
    iterate(history.items)
end
Base.iterate(history::OnceHistory, state) = iterate(history.items, state)

import JuliaForever.Kernel as K

struct LogMarker <: K.Effect
    path::String
end

(marker::LogMarker)() = write(marker.path, "effect ran")
L.record(marker::LogMarker) = (; type="marker", path=marker.path)
