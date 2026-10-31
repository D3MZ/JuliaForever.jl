module RecordedExecutionTests

using Test, Distributed, JuliaForever, SQLite
import JuliaForever.Execution as E
import JuliaForever.Conversation as C
import JuliaForever.Kernel as K
import JuliaForever.History as H

isdefined(Main, :AgentExecutionCases) || Base.include(Main, joinpath(@__DIR__, "agent_execution_cases.jl"))
const Fixtures = Main.AgentExecutionCases

mutable struct FaultHistory <: H.Store
    store::H.Memory
    mode::Symbol
end

H.snapshot(history::FaultHistory) = H.snapshot(history.store)
function H.append!(history::FaultHistory, revision::Integer, batch::Vector)
    event = H.decode_event(only(batch))
    fail = history.mode == :plan && event isa C.Advance ||
           history.mode == :model && event isa K.Observe && event.observation isa C.ModelReply ||
           history.mode == :tool && event isa K.Observe && event.observation isa C.ToolReply ||
           history.mode in (:cancel, :cancel_ack) && event isa C.Cancel ||
           history.mode == :ack && event isa C.Advance
    if fail
        history.mode in (:ack, :cancel_ack) && H.append!(history.store, revision, batch)
        history.mode in (:ack, :cancel_ack) && error("simulated lost acknowledgement")
        return H.Rejected(:failed)
    end
    H.append!(history.store, revision, batch)
end

function worker()
    project = dirname(@__DIR__)
    pid = only(addprocs(1; exeflags=`--startup-file=no --project=$project`))
    remotecall_wait(Core.eval, pid, Main, :(using JuliaForever))
    remotecall_wait(Base.include, pid, Main, joinpath(@__DIR__, "agent_execution_cases.jl"))
    pid
end

function channels()
    RemoteChannel(() -> Channel{Any}(8)), RemoteChannel(() -> Channel{Int}(1)), RemoteChannel(() -> Channel{Nothing}(1))
end

function install(pid, context, dir; gate=nothing)
    requests, started, release = channels()
    if isnothing(gate)
        @test remotecall_fetch(Fixtures.install, pid, context, dir, requests, started, release)
    else
        @test remotecall_fetch(Fixtures.install_gate, pid, context, dir, requests, started, release, gate)
    end
    requests, started, release
end

end
