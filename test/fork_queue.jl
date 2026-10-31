using Test, JSON3, JuliaForever
import JuliaForever.History as QueueForkHistory

mutable struct QueueForkProvider
    requests::Vector{Any}
end

struct ForkQueueTool <: JuliaForever.Tool
    calls::Base.RefValue{Int}
end
JuliaForever.name(::ForkQueueTool) = "fork_queue_tool"
JuliaForever.execute(tool::ForkQueueTool, args) = (tool.calls[] += 1; ToolResult("tool result", false))

mutable struct ForkToolProvider
    requests::Vector{Any}
end
function JuliaForever.stream(provider::ForkToolProvider, messages, tools; parameters=Dict(), on_event=identity)
    push!(provider.requests, deepcopy(messages))
    if length(provider.requests) == 1
        call = Dict("id" => "call-1", "type" => "function", "function" => Dict("name" => "fork_queue_tool", "arguments" => "{}"))
        result = Completion(Dict{String, Any}("role" => "assistant", "content" => nothing, "tool_calls" => [call]), nothing, "tool_calls", true, nothing)
    else
        text = "reply:" * messages[end]["content"]
        on_event((; type=:text, text))
        result = Completion(Dict{String, Any}("role" => "assistant", "content" => text), nothing, "stop", true, nothing)
    end
    on_event((; type=:done, result))
    result
end
function JuliaForever.stream(provider::QueueForkProvider, messages, tools; parameters=Dict(), on_event=identity)
    push!(provider.requests, deepcopy(messages))
    text = "reply:" * messages[end]["content"]
    on_event((; type=:text, text))
    Completion(Dict{String, Any}("role" => "assistant", "content" => text), nothing, "stop", true, nothing)
end

@testset "fork queued user messages" begin
    store = QueueForkHistory.Memory()
    source = QueueForkHistory.Tree(store)
    provider = QueueForkProvider([])
    agent = Agent(provider, []; history=source)
    queued = Ref(false)
    callback = event -> begin
        if event.type == :message_start && event.message["role"] == "assistant" && !queued[]
            queued[] = true
            steer!(agent, "steer")
            followup!(agent, "follow")
        end
    end
    @test respond!(agent, "first"; on_event=identity, on_agent_event=callback) == "reply:follow"
    @test [message["content"] for message in agent.messages] == ["first", "reply:first", "steer", "reply:steer", "follow", "reply:follow"]
    before = QueueForkHistory.snapshot(store).batches

    output = IOBuffer()
    diagnostics = IOBuffer()
    terminal = JuliaForever.Terminal(output, diagnostics, String[])
    forked, history, status = JuliaForever.command!(JuliaForever.ForkCommand(), terminal, agent, source, IOBuffer("2\nreplacement\n"), "", nothing)
    @test status == 0
    @test String(take!(output)) == "reply:replacement\n"
    @test [message["content"] for message in last(provider.requests)] == ["first", "reply:first", "replacement"]
    steercontext = [message["content"] for message in last(provider.requests)][1:end-1]
    @test QueueForkHistory.snapshot(store).batches == before
    close(history)

    source = QueueForkHistory.Tree(store)
    agent = Agent(provider, []; history=source)
    output = IOBuffer()
    terminal = JuliaForever.Terminal(output, IOBuffer(), String[])
    forked, history, status = JuliaForever.command!(JuliaForever.ForkCommand(), terminal, agent, source, IOBuffer("3\nreplacement follow\n"), "", nothing)
    @test status == 0
    @test String(take!(output)) == "reply:replacement follow\n"
    @test [message["content"] for message in last(provider.requests)] == ["first", "reply:first", "steer", "reply:steer", "replacement follow"]
    followcontext = [message["content"] for message in last(provider.requests)][1:end-1]
    @test QueueForkHistory.snapshot(store).batches == before
    if haskey(ENV, "PI_SOURCE")
        source = ENV["PI_SOURCE"]
        @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
        reference = JSON3.read(read(`node $(joinpath(@__DIR__, "fork_pi.mjs")) $source`, String))
        @test steercontext == reference.beforeSteer
        @test followcontext == reference.beforeFollow
    end
    close(history)
end
