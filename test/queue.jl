using Test, JSON3, JuliaForever
import JuliaForever.History as QueueHistory

mutable struct QueueProvider
    started::Channel{Nothing}
    release::Channel{Nothing}
    requests::Vector{Any}
end

function JuliaForever.stream(provider::QueueProvider, messages, tools; parameters=Dict(), on_event=identity)
    push!(provider.requests, deepcopy(messages))
    if length(provider.requests) == 1
        put!(provider.started, nothing)
        take!(provider.release)
    end
    text = "answer"
    on_event((; type=:text, text))
    Completion(Dict{String, Any}("role" => "assistant", "content" => text), nothing, "stop", true, nothing)
end

function queuestart(provider, task)
    @test timedwait(() -> isready(provider.started) || istaskdone(task), 10; pollint=0.01) == :ok
    @test isready(provider.started)
    isready(provider.started) || return false
    take!(provider.started)
    true
end

queuerelease!(provider) = isready(provider.release) || put!(provider.release, nothing)
function queuefinish(provider, task)
    queuerelease!(provider)
    @test timedwait(() -> istaskdone(task), 10; pollint=0.01) == :ok
    istaskdone(task) ? fetch(task) : nothing
end

@testset "restore queued messages" begin
    for recorded in (false, true)
        history = recorded ? QueueHistory.Memory() : nothing
        provider = QueueProvider(Channel{Nothing}(1), Channel{Nothing}(1), Any[])
        agent = Agent(provider, []; history)
        task = Threads.@spawn respond!(agent, "start"; on_event=identity)
        try
            @test timedwait(() -> isready(provider.started) || istaskdone(task), 10; pollint=0.01) == :ok
            @test isready(provider.started)
            isready(provider.started) || continue
            take!(provider.started)
            steer!(agent, "steer one")
            followup!(agent, "follow one")
            steer!(agent, "steer two")
            followup!(agent, "follow two")
            queued = JuliaForever.dequeue!(agent)
            @test queued == (steering=["steer one", "steer two"], followups=["follow one", "follow two"])
            @test isempty(agent.state.steering)
            @test isempty(agent.state.followups)
            put!(provider.release, nothing)
            @test fetch(task) == "answer"
            @test length(provider.requests) == 1
            @test [message["content"] for message in only(provider.requests) if message["role"] == "user"] == ["start"]
            if recorded
                restored = Agent(provider, []; history)
                @test restored.fault === nothing
                @test isempty(restored.state.steering)
                @test isempty(restored.state.followups)
                @test respond!(restored, "fresh"; on_event=identity) == "answer"
                @test [message["content"] for message in provider.requests[end] if message["role"] == "user"] == ["start", "fresh"]
            end
        finally
            isready(provider.release) || put!(provider.release, nothing)
            wait(task)
        end
    end
end

@testset "a stale history keeps queued messages" begin
    history = QueueHistory.Memory()
    provider = QueueProvider(Channel{Nothing}(1), Channel{Nothing}(1), Any[])
    agent = Agent(provider, []; history)
    steer!(agent, "keep steering")
    followup!(agent, "keep followup")
    revision = QueueHistory.snapshot(history).revision
    @test QueueHistory.append!(history, revision, Any["other writer"]) == revision + 1
    @test JuliaForever.dequeue!(agent) == QueueHistory.Rejected(:revision)
    @test agent.state.steering == ["keep steering"]
    @test agent.state.followups == ["keep followup"]
    @test steeringmode!(agent, :all) == QueueHistory.Rejected(:revision)
    @test agent.state.steeringmode isa JuliaForever.Conversation.OneAtATime
end

@testset "an empty queue does not change history" begin
    history = QueueHistory.Memory()
    provider = QueueProvider(Channel{Nothing}(1), Channel{Nothing}(1), Any[])
    agent = Agent(provider, []; history)
    revision = QueueHistory.snapshot(history).revision
    @test JuliaForever.dequeue!(agent) == (steering=String[], followups=String[])
    @test QueueHistory.snapshot(history).revision == revision
end

@testset "queue modes are applied at the next boundary and survive replay" begin
  mktempdir() do dir
    path = joinpath(dir, "session.sqlite")
    history = open(QueueHistory.SQLite, path)
    provider = QueueProvider(Channel{Nothing}(1), Channel{Nothing}(1), Any[])
    agent = Agent(provider, []; history)
    steer!(agent, "s1")
    steer!(agent, "s2")
    followup!(agent, "f1")
    followup!(agent, "f2")
    steeringmode!(agent, :all)
    followupmode!(agent, :all)
    task = Threads.@spawn respond!(agent, "start"; on_event=identity)
    try
        if queuestart(provider, task)
            answer = queuefinish(provider, task)
            @test answer == "answer"
            if answer == "answer"
                users(request) = [message["content"] for message in request if message["role"] == "user"]
                @test users.(provider.requests) == [["start", "s1", "s2"], ["start", "s1", "s2", "f1", "f2"]]
                close(history)
                history = open(QueueHistory.SQLite, path)
                restored = Agent(provider, []; history)
                @test restored.fault === nothing
                @test restored.state.steeringmode == agent.state.steeringmode
                @test restored.state.followupmode == agent.state.followupmode
                @test restored.messages == agent.messages
                exported = JSON3.read(JuliaForever.Logs.json(restored.events))
                @test [row.mode for row in exported if row.type in ("steering_mode", "followup_mode")] == ["all", "all"]
            end
        end
    finally
        queuerelease!(provider)
        close(history)
    end
  end
end

@testset "mode changes affect already queued messages" begin
    provider = QueueProvider(Channel{Nothing}(1), Channel{Nothing}(1), Any[])
    agent = Agent(provider, [])
    steeringmode!(agent, :all)
    followupmode!(agent, :all)
    task = Threads.@spawn respond!(agent, "start"; on_event=identity)
    try
        if queuestart(provider, task)
            steer!(agent, "s1"); steer!(agent, "s2")
            followup!(agent, "f1"); followup!(agent, "f2")
            steeringmode!(agent, :one_at_a_time)
            followupmode!(agent, :one_at_a_time)
            answer = queuefinish(provider, task)
            @test answer == "answer"
            if answer == "answer"
                users(request) = [message["content"] for message in request if message["role"] == "user"]
                @test users.(provider.requests) == [["start"], ["start", "s1"], ["start", "s1", "s2"], ["start", "s1", "s2", "f1"], ["start", "s1", "s2", "f1", "f2"]]
            end
        end
    finally
        queuerelease!(provider)
    end
end
