module RecordedJournalTests

using Test, Distributed, JuliaForever
import JuliaForever.Execution as E
import JuliaForever.History as H
import JuliaForever.Durable as D
import JuliaForever.Conversation as C
import JuliaForever.Kernel as K

isdefined(Main, :AgentExecutionCases) || Base.include(Main, joinpath(@__DIR__, "agent_execution_cases.jl"))
const Fixtures = Main.AgentExecutionCases

@testset "recorded executor: JSONL journal and passive reopen" begin
    if Sys.isunix()
        project = dirname(@__DIR__)
        pid = only(addprocs(1; exeflags=`--startup-file=no --project=$project`))
        try
            remotecall_wait(Core.eval, pid, Main, :(using JuliaForever))
            remotecall_wait(Base.include, pid, Main, joinpath(@__DIR__, "agent_execution_cases.jl"))
            mktempdir() do dir
                requests = RemoteChannel(() -> Channel{Any}(4))
                started = RemoteChannel(() -> Channel{Int}(1))
                release = RemoteChannel(() -> Channel{Nothing}(1))
                context = "recorded-journal-$pid"
                @test remotecall_fetch(Fixtures.install, pid, context, dir, requests, started, release)
                path = joinpath(dir, "history.jsonl")
                store = open(D.Store, path)
                history = H.create(store)
                id = history.id
                pool = E.Executor(pid)
                try
                    agent = Agent(nothing, []; history)
                    @test respond!(agent, "journal"; executor=pool, context).value == "done"
                    @test read(joinpath(dir, "a.txt"), String) == "hello"
                    @test take!(requests).worker == pid
                    @test take!(requests).worker == pid
                    close(store)
                    rm(joinpath(dir, "a.txt"))
                    store = open(D.Store, path)
                    restored = Agent(nothing, []; history=H.Journal(store, id))
                    @test restored.state.phase == C.Complete
                    @test last(collect(K.Replay(restored.initial, restored.events))).state.phase == C.Complete
                    @test !isfile(joinpath(dir, "a.txt"))
                    @test !isready(requests)
                finally
                    close(pool)
                    close(store)
                    remotecall_wait(E.uninstall!, pid, context)
                end
            end
        finally
            rmprocs(pid)
        end
    else
        mktempdir() do dir
            result = open(D.Store, joinpath(dir, "history.jsonl"))
            @test result isa D.Rejected && result.reason == :unsupported_platform
        end
    end
end

end
