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

@testset "simultaneous opposite session switches" begin
    mktempdir() do root
        cd(root) do
            withenv("HOME" => root, "PI_CODING_AGENT_DIR" => joinpath(root, "agent"), "JF_INSTRUCTIONS_DIR" => nothing) do
                path = joinpath(root, ".pi", "skills", "example", "SKILL.md")
                mkpath(dirname(path))
                write(path, "---\nname: example\ndescription: test\n---\nbody\n")
                reached = Threads.Atomic{Int}(0)
                release = Channel{Nothing}(2)
                stores = [BarrierStore(H.Memory(), reached, release, false) for _ in 1:2]
                histories = H.Tree.(stores)
                agents = [Agent(ParallelProvider(), [Read(root)]; history=history) for history in histories]
                terminals = [JuliaForever.Terminal(IOBuffer(), IOBuffer(), String[]) for _ in 1:2]
                stores[1].enabled = stores[2].enabled = true
                tasks = [Threads.@spawn JuliaForever.resume!(terminals[i], agents[i], histories[i], histories[3-i]) for i in 1:2]
                ready = timedwait(() -> reached[] == 2, 30)
                @test ready == :ok
                put!(release, nothing)
                put!(release, nothing)
                done = timedwait(() -> all(istaskdone, tasks), 30)
                @test done == :ok
                done == :ok || exit(1)
                results = fetch.(tasks)
                @test [result[3] for result in results] == [0, 0]
                @test all(result -> any(m -> occursin("<name>example</name>", get(m, "content", "")), result[1].messages), results)
            end
        end
    end
end
