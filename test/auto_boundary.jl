using HTTP

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

@testset "cancel a native automatic summary" begin
    ready, release = Channel{Nothing}(1), Channel{Nothing}(1)
    requests = Threads.Atomic{Int}(0)
    events = []
    server = HTTP.listen!("127.0.0.1", 0; listenany=true) do io
        HTTP.startread(io)
        read(io)
        if Threads.atomic_add!(requests, 1) == 0
            HTTP.setheader(io, "Content-Type" => "text/event-stream")
            HTTP.startwrite(io)
            chunk = (; choices=[(; index=0, delta=(; role="assistant", content="done"), finish_reason="stop")])
            usage = (; choices=[], usage=(; prompt_tokens=81, completion_tokens=0))
            write(io, "data: ", JSON3.write(chunk), "\n\ndata: ", JSON3.write(usage), "\n\ndata: [DONE]\n\n")
        else
            put!(ready, nothing)
            take!(release)
            HTTP.setheader(io, "Content-Type" => "application/json")
            HTTP.startwrite(io)
            write(io, "{}")
        end
    end
    task = nothing
    try
        model = OpenAI("http://$(HTTP.server_addr(server))/v1", "fixture", "synthetic")
        history = CompactHistory.Memory()
        agent = compactagent(model; history)
        task = Threads.@spawn respond!(agent, "next"; auto_compaction=JuliaForever.AutoCompaction(100, 20), on_event=identity, on_agent_event=event -> push!(events, event))
        @test timedwait(() -> isready(ready) || istaskdone(task), 15; pollint=0.01) == :ok
        @test isready(ready)
        if isready(ready)
            take!(ready)
            @test cancel!(agent)
            stopped = timedwait(() -> istaskdone(task), 2; pollint=0.01)
            @test stopped == :ok
            stopped == :ok || put!(release, nothing)
            @test fetch(task) == "done"
            @test requests[] == 2
            @test [(event.type, event.reason) for event in events if event.type in (:auto_compaction_start, :auto_compaction_end)] == [(:auto_compaction_start, :threshold), (:auto_compaction_end, :threshold)]
            @test only(event for event in events if event.type == :auto_compaction_end).result == :cancelled
            @test !any(message -> occursin("<summary>", string(get(message, "content", ""))), agent.messages)
            @test Agent(model, []; history).messages == agent.messages
        end
    finally
        isready(release) || put!(release, nothing)
        close(server)
        wait(server)
        task === nothing || wait(task)
    end
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
