using Test, JuliaForever
import JuliaForever.History as ResumeHistory
import JuliaForever.SessionCatalog as ResumeCatalog

struct ResumeProvider end
JuliaForever.complete(::ResumeProvider, messages, tools; kwargs...) = Dict{String, Any}("role" => "assistant", "content" => "ok")

mutable struct ResumeStore <: ResumeHistory.Store
    memory::ResumeHistory.Memory
    closes::Int
    snapshot_failure::Any
    close_failure::Any
end
ResumeStore() = ResumeStore(ResumeHistory.Memory(), 0, nothing, nothing)
function ResumeHistory.snapshot(store::ResumeStore)
    isnothing(store.snapshot_failure) || throw(store.snapshot_failure)
    ResumeHistory.snapshot(store.memory)
end
Base.append!(store::ResumeStore, revision::Integer, batch::Vector) = append!(store.memory, revision, batch)
function Base.close(store::ResumeStore)
    store.closes += 1
    isnothing(store.close_failure) || throw(store.close_failure)
    nothing
end
resumetree() = ResumeHistory.Tree(ResumeStore())

mutable struct ResumeDatabase
    closes::Int
end
ResumeHistory.snapshot(::ResumeHistory.SQLite{ResumeDatabase}) = throw(ArgumentError("snapshot failed"))
Base.close(store::ResumeHistory.SQLite{ResumeDatabase}) = (store.db.closes += 1; nothing)

mutable struct ResumeCountingProvider
    calls::Int
end
function JuliaForever.complete(provider::ResumeCountingProvider, messages, tools; kwargs...)
    provider.calls += 1
    Dict{String, Any}("role" => "assistant", "content" => "ok")
end

struct ResumeQueueInput <: IO
    input::IOBuffer
    agent::Agent
end
Base.eof(input::ResumeQueueInput) = eof(input.input)
function Base.readline(input::ResumeQueueInput; keep=false)
    steer!(input.agent, "late synthetic-key")
    readline(input.input; keep)
end

mutable struct ResumeRaceStore <: ResumeHistory.Store
    memory::ResumeHistory.Memory
    hook::Function
    closes::Int
end
ResumeHistory.snapshot(store::ResumeRaceStore) = (store.hook(); ResumeHistory.snapshot(store.memory))
Base.append!(store::ResumeRaceStore, revision::Integer, batch::Vector) = append!(store.memory, revision, batch)
Base.close(store::ResumeRaceStore) = (store.closes += 1; nothing)
