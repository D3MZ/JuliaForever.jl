@testset "automatic compaction at response boundary" begin
    used(n) = JuliaForever.Usage(n, 0, 0, 0, 0, n, nothing)
    answer(n) = JuliaForever.Completion(Dict{String,Any}("role"=>"assistant", "content"=>"done"), used(n), "stop", true, nothing)
    for n in (80, 81)
        mktempdir() do dir
            path = joinpath(dir, "history.sqlite")
            history = open(CompactHistory.SQLite, path)
            provider = CompactProvider(answer(n), Any[])
            agent = compactagent(provider; history)
            calls = Ref(0)
            events = []
            result = respond!(agent, "next"; on_agent_event=event -> push!(events, event), auto_compaction=JuliaForever.AutoCompaction(100,20), summarize=_ -> (calls[] += 1; "saved"))
            @test result == "done"
            @test calls[] == (n == 81 ? 1 : 0)
            compactions = [event for event in events if event.type == :auto_compaction_end]
            @test length(compactions) == (n == 81 ? 1 : 0)
            n == 81 && @test only(compactions).result == "saved"
            expected = deepcopy(agent.messages)
            close(history)
            history = open(CompactHistory.SQLite, path)
            restored = Agent(provider, []; history)
            @test restored.messages == expected
            close(history)
        end
    end
    provider = CompactProvider(answer(81), Any[])
    agent = compactagent(provider; history=CompactHistory.Memory())
    @test respond!(agent, "next"; auto_compaction=JuliaForever.AutoCompaction(100,20), summarize=_ -> CompactHistory.Rejected(:summary_failed)) == "done"
    @test !any(m -> occursin("<summary>", string(get(m, "content", ""))), agent.messages)
    cancelled = compactagent(provider; history=CompactHistory.Memory())
    @test respond!(cancelled, "next"; auto_compaction=JuliaForever.AutoCompaction(100,20), summarize=_ -> (cancel!(cancelled); "ignored")) == "done"
    @test !any(m -> occursin("<summary>", string(get(m, "content", ""))), cancelled.messages)
end

@testset "automatic boundary skips disabled and aborted turns" begin
    used = JuliaForever.Usage(81, 0, 0, 0, 0, 81, nothing)
    reply = JuliaForever.Completion(Dict{String,Any}("role"=>"assistant", "content"=>"done"), used, "stop", true, nothing)
    for enabled in (false, true)
        agent = compactagent(CompactProvider(reply, Any[]); history=CompactHistory.Memory())
        calls = Ref(0)
        callback = event -> event.type == :agent_start && enabled && cancel!(agent)
        result = respond!(agent, "next"; on_agent_event=callback, auto_compaction=JuliaForever.AutoCompaction(100, 20; enabled), summarize=_ -> (calls[] += 1; "unused"))
        @test result == (enabled ? :cancelled : "done")
        @test calls[] == 0
    end
end
