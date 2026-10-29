using Test, Distributed, JuliaForever
const KK = JuliaForever.Kernel
const KE = JuliaForever.Execution

include("kernel_execution_cases.jl")
const KC = KernelExecutionCases

@testset "kernel effects through executor" begin
    initial = KK.State("conversation")
    planned = KK.step(initial, KK.Plan(0, "double", KK.Call("double", 21)))
    pending = only(planned.effects)
    localpool = KE.Executor(myid(); capacity=1)
    completed = fetch(KE.submit!(localpool, pending, 1))
    @test completed isa KE.Completed
    @test (completed.id, completed.attempt, completed.worker, completed.value) == ("double", 1, myid(), (42, myid()))
    observed = KK.step(planned.state, KK.Observe(planned.state.revision, completed.id, KK.Return(completed.value)))
    @test observed isa KK.Applied
    @test isempty(observed.state.pending)
    @test only(observed.state.observations).observation.value == (42, myid())

    planned = KK.step(observed.state, KK.Plan(observed.state.revision, "bad", KC.BadEffect()))
    failure = fetch(KE.submit!(localpool, only(planned.effects), 2))
    @test failure isa KE.Failed
    @test (failure.id, failure.attempt) == ("bad", 2)
    @test occursin("effect failed", failure.message)
    observed = KK.step(planned.state, KK.Observe(planned.state.revision, failure.id, KK.Fail(failure.message)))
    @test observed isa KK.Applied
    @test only(filter(item -> item.id == "bad", observed.state.observations)).observation isa KK.Fail
    close(localpool)

    project = dirname(@__DIR__)
    pid = only(addprocs(1; exeflags=`--startup-file=no --project=$project`))
    try
        remotecall_wait(Core.eval, pid, Main, :(using JuliaForever))
        remotecall_wait(Base.include, pid, Main, joinpath(@__DIR__, "kernel_execution_cases.jl"))
        pool = KE.Executor(pid; capacity=1)
        planned = KK.step(observed.state, KK.Plan(observed.state.revision, "remote", KK.Call("double", 12)))
        pending = only(planned.effects)
        completed = fetch(KE.submit!(pool, pending, 4))
        @test completed isa KE.Completed
        @test (completed.id, completed.attempt, completed.worker, completed.value) == ("remote", 4, pid, (24, pid))
        observed = KK.step(planned.state, KK.Observe(planned.state.revision, completed.id, KK.Return(completed.value)))
        @test observed isa KK.Applied
        @test isempty(observed.state.pending)
        close(pool)
    finally
        rmprocs(pid)
    end
end
