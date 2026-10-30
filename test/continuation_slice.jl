using Test, JuliaForever
mutable struct ContinuationProvider
    replies::Vector{String}
    requests::Vector{Any}
end
function JuliaForever.complete(p::ContinuationProvider, messages, tools)
    push!(p.requests, deepcopy(messages))
    Dict{String, Any}("role" => "assistant", "content" => popfirst!(p.replies))
end
@testset "continuation" begin
    p = ContinuationProvider(["done"], [])
    agent = Agent(p, [])
    @test JuliaForever.continue!(agent) == :empty
    @test isempty(p.requests)
    push!(agent.messages, Dict("role" => "user", "content" => "hello"))
    events = Symbol[]
    @test JuliaForever.continue!(agent; on_agent_event=e -> push!(events, e.type)) == "done"
    @test [m["role"] for m in p.requests[1]] == ["user"]
    @test events == [:agent_start, :turn_start, :message_start, :message_end, :turn_end, :agent_end]
    @test JuliaForever.continue!(agent) == :assistant_tail
    @test length(p.requests) == 1
end

@testset "assistant tail and recorded continuation" begin
    for history in (nothing, JuliaForever.History.Memory())
        p = ContinuationProvider(["first", "second", "third"], [])
        agent = Agent(p, []; history)
        @test respond!(agent, "initial") == "first"
        steer!(agent, "steer")
        followup!(agent, "follow")
        busy = Any[]
        events = Symbol[]
        @test JuliaForever.continue!(agent; on_agent_event=e -> begin
            push!(events, e.type)
            e.type == :agent_end && push!(busy, JuliaForever.continue!(agent))
        end) == "third"
        @test busy == [:busy]
        @test [m["content"] for m in p.requests[2] if m["role"] == "user"] == ["initial", "steer"]
        @test [m["content"] for m in p.requests[3] if m["role"] == "user"] == ["initial", "steer", "follow"]
        @test first(events) == :agent_start && last(events) == :agent_end
        if history !== nothing
            restored = Agent(p, []; history)
            @test restored.messages == agent.messages
            @test JuliaForever.continue!(restored) == :assistant_tail
        end
    end
end

@testset "tool tail and history fault" begin
    p = ContinuationProvider(["resumed"], [])
    agent = Agent(p, [])
    append!(agent.messages, [Dict("role" => "assistant", "content" => "call"), Dict("role" => "tool", "content" => "result", "tool_call_id" => "one")])
    @test continue!(agent) == "resumed"
    @test [m["role"] for m in only(p.requests)] == ["assistant", "tool"]
    history = JuliaForever.History.Memory()
    p = ContinuationProvider(["unused"], [])
    agent = Agent(p, []; history)
    @test JuliaForever.History.append!(history, 1, Any["racing writer"]) == 2
    push!(agent.messages, Dict("role" => "user", "content" => "uncommitted"))
    @test continue!(agent) == JuliaForever.History.Rejected(:revision)
    @test isempty(p.requests)
end
