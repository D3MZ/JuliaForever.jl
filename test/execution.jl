using Test, Distributed, JuliaForever

const E = JuliaForever.Execution
include("execution_cases.jl")
const ExecCases = ExecutionCases

function channels()
    RemoteChannel(() -> Channel{Int}(1)), RemoteChannel(() -> Channel{Nothing}(1))
end

@testset "local execution and failures" begin
    pool = E.Executor(myid(); capacity=1)
    first = E.submit!(pool, "one", 1, ExecCases.Value(7))
    completed = fetch(first)
    @test completed isa E.Completed
    @test (completed.id, completed.attempt, completed.value) == ("one", 1, (7, myid()))
    @test fetch(first) === completed
    failure = fetch(E.submit!(pool, "bad", 2, ExecCases.Fail()))
    @test failure isa E.Failed
    @test (failure.id, failure.attempt, failure.worker) == ("bad", 2, myid())
    @test occursin("work failed", failure.message)
    @test fetch(E.submit!(pool, "next", 1, ExecCases.Value(9))).value == (9, myid())
    close(pool)
    @test_throws InvalidStateException E.submit!(pool, "closed", 1, ExecCases.Value(0))
end

@testset "queued and cooperative cancellation" begin
    pool = E.Executor(myid(); capacity=1)
    started, release = channels()
    active = E.submit!(pool, "active", 1, ExecCases.Gate(started, release, false))
    @test take!(started) == myid()
    queued = E.submit!(pool, "queued", 1, ExecCases.Gate(started, release, false))
    E.cancel!(queued)
    E.cancel!(queued)
    put!(release, nothing)
    @test fetch(active).value == :released
    outcome = fetch(queued)
    @test outcome isa E.Cancelled
    @test (outcome.id, outcome.attempt) == ("queued", 1)
    @test !isready(started)

    started, release = channels()
    active = E.submit!(pool, "cooperative", 3, ExecCases.Gate(started, release, true))
    @test take!(started) == myid()
    E.cancel!(active)
    @test fetch(active) isa E.Cancelled

    started, release = channels()
    active = E.submit!(pool, "ignores-cancel", 1, ExecCases.Gate(started, release, false))
    @test take!(started) == myid()
    E.cancel!(active)
    put!(release, nothing)
    @test fetch(active).value == :released
    close(pool)
end

@testset "bounded queue and worker slots" begin
    pool = E.Executor(myid(); capacity=1)
    started, release = channels()
    active = E.submit!(pool, "active", 1, ExecCases.Gate(started, release, false))
    take!(started)
    queued = E.submit!(pool, "queued", 1, ExecCases.Value(2))
    ready = Channel{Nothing}(1)
    blocked = @async begin
        put!(ready, nothing)
        E.submit!(pool, "queued", 2, ExecCases.Value(3))
    end
    take!(ready)
    yield()
    @test !istaskdone(blocked)
    put!(release, nothing)
    @test fetch(active).value == :released
    @test (fetch(queued).id, fetch(queued).attempt, fetch(queued).value) == ("queued", 1, (2, myid()))
    second = fetch(blocked)
    @test (fetch(second).id, fetch(second).attempt, fetch(second).value) == ("queued", 2, (3, myid()))
    close(pool)

    pool = E.Executor(myid(), myid(); capacity=1)
    started1, release1 = channels()
    started2, release2 = channels()
    first = E.submit!(pool, "first", 1, ExecCases.Gate(started1, release1, false))
    second = E.submit!(pool, "second", 1, ExecCases.Gate(started2, release2, false))
    @test take!(started1) == myid()
    @test take!(started2) == myid()
    put!(release1, nothing)
    put!(release2, nothing)
    @test fetch(first).value == :released
    @test fetch(second).value == :released
    close(pool)
end

@testset "close drains admitted work" begin
    pool = E.Executor(myid(); capacity=1)
    started, release = channels()
    active = E.submit!(pool, "active", 1, ExecCases.Gate(started, release, false))
    take!(started)
    queued = E.submit!(pool, "queued", 1, ExecCases.Value(2))
    closing = @async close(pool)
    yield()
    @test !istaskdone(closing)
    @test_throws InvalidStateException E.submit!(pool, "closed", 1, ExecCases.Value(0))
    put!(release, nothing)
    @test fetch(active).value == :released
    @test fetch(queued).value == (2, myid())
    @test fetch(closing) === nothing
end

@testset "distributed execution" begin
    project = dirname(@__DIR__)
    added = addprocs(1; exeflags=`--startup-file=no --project=$project`)
    pid = only(added)
    try
        remotecall_wait(Core.eval, pid, Main, :(using JuliaForever))
        remotecall_wait(Base.include, pid, Main, joinpath(@__DIR__, "execution_cases.jl"))
        pool = E.Executor(pid; capacity=1)
        completed = fetch(E.submit!(pool, "remote", 1, ExecCases.Value(8)))
        @test completed isa E.Completed
        @test completed.value == (8, pid)
        failure = fetch(E.submit!(pool, "remote-error", 1, ExecCases.Fail()))
        @test failure isa E.Failed
        @test failure.worker == pid
        @test occursin("work failed", failure.message)
        started, release = channels()
        active = E.submit!(pool, "remote-cancel", 1, ExecCases.Gate(started, release, true))
        @test take!(started) == pid
        E.cancel!(active)
        @test fetch(active) isa E.Cancelled
        close(pool)

        pool = E.Executor(pid, pid; capacity=1)
        started1, release1 = channels()
        started2, release2 = channels()
        first = E.submit!(pool, "remote-first", 1, ExecCases.Gate(started1, release1, false))
        second = E.submit!(pool, "remote-second", 1, ExecCases.Gate(started2, release2, false))
        @test take!(started1) == pid
        @test take!(started2) == pid
        put!(release1, nothing)
        put!(release2, nothing)
        @test fetch(first).value == :released
        @test fetch(second).value == :released
        close(pool)
    finally
        rmprocs(pid)
    end
end

@testset "worker exit" begin
    project = dirname(@__DIR__)
    pid = only(addprocs(1; exeflags=`--startup-file=no --project=$project`))
    remotecall_wait(Core.eval, pid, Main, :(using JuliaForever))
    remotecall_wait(Base.include, pid, Main, joinpath(@__DIR__, "execution_cases.jl"))
    pool = E.Executor(pid; capacity=1)
    started, release = channels()
    active = E.submit!(pool, "worker-exit", 1, ExecCases.Crash(started, release))
    @test take!(started) == pid
    queued = E.submit!(pool, "cancelled-before-exit", 1, ExecCases.Value(1))
    E.cancel!(queued)
    put!(release, nothing)
    failure = fetch(active)
    @test fetch(queued) isa E.Cancelled
    @test failure isa E.Failed
    @test (failure.id, failure.attempt, failure.worker) == ("worker-exit", 1, pid)
    @test fetch(E.submit!(pool, "after-exit", 1, ExecCases.Value(1))) isa E.Failed
    close(pool)
end
