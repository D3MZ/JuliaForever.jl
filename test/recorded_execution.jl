module RecordedExecutionTests

using Test, Distributed, JuliaForever, SQLite
import JuliaForever.Execution as E
import JuliaForever.Conversation as C
import JuliaForever.Kernel as K
import JuliaForever.History as H

isdefined(Main, :AgentExecutionCases) || Base.include(Main, joinpath(@__DIR__, "agent_execution_cases.jl"))
const Fixtures = Main.AgentExecutionCases

@testset "recorded executor: durable plans, observations, and passive replay" begin
    project = dirname(@__DIR__)
    pid = only(addprocs(1; exeflags=`--startup-file=no --project=$project`))
    try
        remotecall_wait(Core.eval, pid, Main, :(using JuliaForever))
        remotecall_wait(Base.include, pid, Main, joinpath(@__DIR__, "agent_execution_cases.jl"))
        mktempdir() do dir
            requests = RemoteChannel(() -> Channel{Any}(8))
            started = RemoteChannel(() -> Channel{Int}(1))
            release = RemoteChannel(() -> Channel{Nothing}(1))
            context = "recorded-happy-$pid"
            @test remotecall_fetch(Main.AgentExecutionCases.install, pid, context, dir, requests, started, release)
            path = joinpath(dir, "history.sqlite")
            history = open(H.SQLite, path)
            agent = Agent(nothing, []; history)
            pool = E.Executor(pid)
            try
                active = @async respond!(agent, "block-once"; executor=pool, context)
                @test take!(started) == pid
                pending = Agent(nothing, []; history)
                @test pending.state.phase == C.WaitingModel
                @test respond!(pending, "again"; executor=pool, context) == H.Rejected(:uncertain_effect)
                put!(release, nothing)
                result = fetch(active)
                @test result.value == "done"
                @test length(result.models) == 2
                @test read(joinpath(dir, "a.txt"), String) == "hello"
                @test take!(requests).worker == pid
                @test take!(requests).worker == pid
                revision = agent.state.revision
                close(history)
                rm(joinpath(dir, "a.txt"))
                history = open(H.SQLite, path)
                replayed = Agent(nothing, []; history)
                @test replayed.state.phase == C.Complete
                @test replayed.state.revision == revision
                @test last(collect(K.Replay(replayed.initial, replayed.events))).state.phase == C.Complete
                @test !isfile(joinpath(dir, "a.txt"))
                @test !isready(requests)
            finally
                close(pool)
                close(history)
                remotecall_wait(E.uninstall!, pid, context)
            end
        end
    finally
        rmprocs(pid)
    end
end

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

@testset "recorded executor: failed appends and competing writers stop dispatch" begin
    pid = worker()
    pool = E.Executor(pid)
    try
        mktempdir() do dir
            for mode in (:plan, :model, :tool)
                context = "recorded-fail-$mode-$pid"
                requests, _, _ = install(pid, context, dir)
                store = H.Memory()
                history = FaultHistory(store, mode)
                agent = Agent(nothing, []; history)
                result = respond!(agent, "failure"; executor=pool, context)
                @test result.value == H.Rejected(:failed)
                @test respond!(agent, "again"; executor=pool, context) == H.Rejected(:failed)
                reopened = Agent(nothing, []; history=store)
                if mode == :plan
                    @test reopened.fault == H.Rejected(:incomplete_turn)
                    @test !isready(requests) && !isfile(joinpath(dir, "a.txt"))
                elseif mode == :model
                    @test reopened.fault == H.Rejected(:uncertain_effect)
                    @test take!(requests).worker == pid
                    @test !isready(requests) && !isfile(joinpath(dir, "a.txt"))
                else
                    @test reopened.fault == H.Rejected(:uncertain_effect)
                    @test take!(requests).worker == pid
                    @test !isready(requests) && read(joinpath(dir, "a.txt"), String) == "hello"
                    @test respond!(reopened, "again"; executor=pool, context) == H.Rejected(:uncertain_effect)
                    @test read(joinpath(dir, "a.txt"), String) == "hello"
                    rm(joinpath(dir, "a.txt"))
                end
                @test JuliaForever.abandon!(reopened, "inspected") isa K.Applied
                remotecall_wait(E.uninstall!, pid, context)
            end

            context = "recorded-race-$pid"
            requests, _, _ = install(pid, context, dir)
            history = H.Memory()
            agent = Agent(nothing, []; history)
            result = respond!(agent, "race"; executor=pool, context, on_agent_event=event -> begin
                if event.type == :tool_execution_start
                    event = C.Steer(agent.state.revision, "other writer")
                    @test H.append!(history, agent.history_revision, Any[H.encode(event)]) == agent.history_revision + 1
                    @test JuliaForever.steer!(agent, "stale writer") == H.Rejected(:revision)
                end
            end)
            @test result.value == H.Rejected(:revision)
            @test take!(requests).worker == pid
            @test !isready(requests) && !isfile(joinpath(dir, "a.txt"))
            restored = Agent(nothing, []; history)
            @test restored.fault == H.Rejected(:uncertain_effect)
            @test respond!(restored, "again"; executor=pool, context) == H.Rejected(:uncertain_effect)
            remotecall_wait(E.uninstall!, pid, context)

            context = "recorded-callback-$pid"
            requests, _, _ = install(pid, context, dir)
            history = H.Memory()
            agent = Agent(nothing, []; history)
            @test_throws ErrorException respond!(agent, "callback"; executor=pool, context, on_agent_event=event -> begin
                if event.type == :tool_execution_end
                    snapshot = Agent(nothing, []; history)
                    @test count(item -> item isa K.Observe && item.observation isa C.ToolReply, snapshot.events) == 1
                    @test snapshot.fault == H.Rejected(:incomplete_turn)
                    error("callback failed")
                end
            end)
            @test agent.fault == H.Rejected(:incomplete_turn)
            @test take!(requests).worker == pid
            @test !isready(requests) && read(joinpath(dir, "a.txt"), String) == "hello"
            restored = Agent(nothing, []; history)
            @test JuliaForever.abandon!(restored, "observed") isa K.Applied
            @test count(message -> message["role"] == "tool", restored.messages) == 1
            @test read(joinpath(dir, "a.txt"), String) == "hello"
            rm(joinpath(dir, "a.txt"))
            remotecall_wait(E.uninstall!, pid, context)

            context = "recorded-ack-$pid"
            requests, _, _ = install(pid, context, dir)
            store = H.Memory()
            agent = Agent(nothing, []; history=FaultHistory(store, :ack))
            @test_throws ErrorException respond!(agent, "lost ack"; executor=pool, context)
            @test agent.fault == H.Rejected(:uncertain)
            @test JuliaForever.abandon!(agent, "no") == H.Rejected(:uncertain)
            @test !isready(requests) && !isfile(joinpath(dir, "a.txt"))
            restored = Agent(nothing, []; history=store)
            @test restored.fault == H.Rejected(:uncertain_effect)
            @test respond!(restored, "again"; executor=pool, context) == H.Rejected(:uncertain_effect)
            remotecall_wait(E.uninstall!, pid, context)
        end
    finally
        close(pool)
        rmprocs(pid)
    end
end

@testset "recorded executor: worker loss before and after effects" begin
    for before in (true, false)
        pid = worker()
        pool = E.Executor(pid)
        try
            mktempdir() do dir
                context = "recorded-crash-$before-$pid"
                requests, started, _ = install(pid, context, dir; gate=before)
                path = joinpath(dir, "history.sqlite")
                history = open(H.SQLite, path)
                agent = Agent(nothing, []; history)
                active = @async respond!(agent, "crash"; executor=pool, context)
                @test take!(started) == pid
                @test isfile(joinpath(dir, "a.txt")) == !before
                rmprocs(pid)
                @test timedwait(() -> istaskdone(active), 15) == :ok
                result = fetch(active)
                @test result.value isa E.Uncertain
                @test result.value.cause isa E.Failed
                @test result.value.cause.worker == pid
                @test agent.fault == H.Rejected(:uncertain_effect)
                @test respond!(agent, "again"; executor=pool, context) == H.Rejected(:uncertain_effect)
                @test isempty(filter(event -> event isa K.Observe && event.observation isa C.ToolReply, agent.events))
                @test take!(requests).worker == pid
                @test !isready(requests)
                close(history)
                history = open(H.SQLite, path)
                restored = Agent(nothing, []; history)
                @test restored.state.phase == C.WaitingTools
                @test respond!(restored, "again"; executor=pool, context) == H.Rejected(:uncertain_effect)
                @test JuliaForever.abandon!(restored, "inspected effect") isa K.Applied
                close(history)
                history = open(H.SQLite, path)
                restored = Agent(nothing, []; history)
                @test restored.state.phase == C.Incomplete
                @test isfile(joinpath(dir, "a.txt")) == !before
                before || @test read(joinpath(dir, "a.txt"), String) == "hello"
                @test !isready(requests)
                close(history)
            end
        finally
            close(pool)
            pid in workers() && rmprocs(pid)
        end
    end
end

@testset "recorded executor: queued and in-flight cancellation" begin
    pid = worker()
    pool = E.Executor(pid; capacity=1)
    try
        mktempdir() do dir
            for mode in (:normal, :cancel, :cancel_ack)
                context = "recorded-cancel-$mode-$pid"
                requests, started, release = install(pid, context, dir)
                pending = only(K.step(C.State("occupy"), C.Input(0, "block")).effects)
                blocker = E.submit!(pool, pending, 1, context)
                @test take!(started) == pid
                store = H.Memory()
                history = mode == :normal ? store : FaultHistory(store, mode)
                agent = Agent(nothing, []; history)
                active = @async respond!(agent, "queued"; executor=pool, context)
                @test timedwait(() -> lock(() -> !isnothing(agent.handle), agent.lock), 10) == :ok
                if mode == :cancel_ack
                    @test_throws ErrorException JuliaForever.cancel!(agent)
                else
                    @test JuliaForever.cancel!(agent) == (mode == :normal ? true : H.Rejected(:failed))
                end
                put!(release, nothing)
                @test fetch(blocker) isa E.Completed
                result = fetch(active)
                @test result.value == (mode == :normal ? :cancelled : H.Rejected(mode == :cancel ? :failed : :uncertain))
                @test take!(requests).worker == pid
                @test !isready(requests) && !isfile(joinpath(dir, "a.txt"))
                restored = Agent(nothing, []; history=store)
                @test mode == :normal ? restored.state.phase == C.Cancelled : restored.fault == H.Rejected(:uncertain_effect)
                remotecall_wait(E.uninstall!, pid, context)
            end

            context = "recorded-in-flight-$pid"
            requests, started, release = install(pid, context, dir; gate=false)
            history = H.Memory()
            agent = Agent(nothing, []; history)
            active = @async respond!(agent, "cancel-in-flight"; executor=pool, context)
            @test take!(started) == pid
            @test JuliaForever.cancel!(agent)
            put!(release, nothing)
            @test fetch(active).value == :cancelled
            @test read(joinpath(dir, "a.txt"), String) == "hello"
            @test take!(requests).worker == pid
            @test !isready(requests)
            restored = Agent(nothing, []; history)
            @test restored.state.phase == C.Cancelled
            @test count(event -> event isa K.Observe && event.observation isa C.ToolReply, restored.events) == 1
            remotecall_wait(E.uninstall!, pid, context)
        end
    finally
        close(pool)
        rmprocs(pid)
    end
end

@testset "recorded executor preserves model usage and errors in turn results" begin
    pid = worker()
    pool = E.Executor(pid)
    try
        mktempdir() do dir
            context = "recorded-metadata-$pid"
            requests, _, _ = install(pid, context, dir)
            usage = respond!(Agent(nothing, []; history=H.Memory()), "usage"; executor=pool, context)
            @test usage.value == "done" && only(usage.models).usage.total == 2
            @test take!(requests).worker == pid
            history = H.Memory()
            partial = respond!(Agent(nothing, []; history), "error-metadata"; executor=pool, context)
            @test partial.value == E.Rejected(:incomplete_model)
            @test only(partial.models).error == "private error detail"
            @test take!(requests).worker == pid
            @test Agent(nothing, []; history).state.phase == C.Incomplete
            history = H.Memory()
            failed = respond!(Agent(nothing, []; history), "error-done"; executor=pool, context)
            @test failed.value == E.Rejected(:provider_error)
            @test only(failed.models).error == "private error detail"
            @test take!(requests).worker == pid
            @test Agent(nothing, []; history).state.phase == C.Incomplete

            closed = E.Executor(pid)
            close(closed)
            history = H.Memory()
            result = respond!(Agent(nothing, []; history), "closed"; executor=closed, context)
            @test result.value isa E.Uncertain
            @test result.value.cause == E.Rejected(:submission)
            @test Agent(nothing, []; history).fault == H.Rejected(:uncertain_effect)
            @test !isready(requests)
            remotecall_wait(E.uninstall!, pid, context)
        end
    finally
        close(pool)
        rmprocs(pid)
    end
end

end
