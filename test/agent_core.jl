using JSON3

mutable struct AgentFixture
    replies::Vector{Completion}
    requests::Vector{Any}
end

function JuliaForever.stream(provider::AgentFixture, messages, tools; parameters=Dict(), on_event=identity)
    push!(provider.requests, deepcopy(messages))
    result = popfirst!(provider.replies)
    content = result.message["content"]
    isnothing(content) || on_event((; type=:text, text=content))
    on_event((; type=result.done ? :done : :incomplete, result))
    result
end

function completion(content; calls=[], finish="stop", done=true)
    message = Dict{String, Any}("role" => "assistant", "content" => content)
    isempty(calls) || (message["tool_calls"] = calls)
    Completion(message, nothing, finish, done, done ? nothing : "interrupted")
end

call(id, name, args) = Dict("id" => id, "type" => "function", "function" => Dict("name" => name, "arguments" => JSON3.write(args)))

@testset "agent lifecycle and queues" begin
    mktempdir() do dir
        calls = [call("one", "write", (; path="a.txt", content="first")), call("two", "write", (; path="b.txt", content="second"))]
        provider = AgentFixture([completion(nothing; calls, finish="tool_calls"), completion("steered one"), completion("steered two"), completion("followed")], [])
        agent = Agent(provider, [Write(dir)])
        events = []
        raw = []
        result = respond!(agent, "start"; on_event=event -> push!(raw, event), on_agent_event=event -> begin
            push!(events, event)
            if event.type == :tool_execution_start && event.tool_call_id == "one"
                JuliaForever.steer!(agent, "steer one")
                JuliaForever.steer!(agent, "steer two")
                JuliaForever.followup!(agent, "follow up")
            end
        end)
        @test result == "followed"
        @test read(joinpath(dir, "a.txt"), String) == "first"
        @test read(joinpath(dir, "b.txt"), String) == "second"
        @test [message["content"] for message in provider.requests[2] if message["role"] == "user"] == ["start", "steer one"]
        @test [message["content"] for message in provider.requests[3] if message["role"] == "user"] == ["start", "steer one", "steer two"]
        @test [message["content"] for message in provider.requests[4] if message["role"] == "user"] == ["start", "steer one", "steer two", "follow up"]
        @test [message["tool_call_id"] for message in provider.requests[2] if message["role"] == "tool"] == ["one", "two"]
        @test [event.type for event in events if event.type != :message_update] == [:agent_start, :turn_start, :message_start, :message_end, :message_start, :message_end, :tool_execution_start, :tool_execution_end, :message_start, :message_end, :tool_execution_start, :tool_execution_end, :message_start, :message_end, :turn_end, :turn_start, :message_start, :message_end, :message_start, :message_end, :turn_end, :turn_start, :message_start, :message_end, :message_start, :message_end, :turn_end, :turn_start, :message_start, :message_end, :message_start, :message_end, :turn_end, :agent_end]
        @test [event.type for event in raw] == [:done, :text, :done, :text, :done, :text, :done]
        @test [event.message["content"] for event in events if event.type == :message_update] == ["steered one", "steered two", "followed"]
        @test [message["role"] for message in last(events).messages] == ["user", "assistant", "tool", "tool", "user", "assistant", "user", "assistant", "user", "assistant"]
    end
end

@testset "agent rejects truncated tool calls" begin
    mktempdir() do dir
        calls = [call("one", "write", (; path="a.txt", content="partial"))]
        provider = AgentFixture([completion(nothing; calls, finish="length"), completion("recovered")], [])
        agent = Agent(provider, [Write(dir)])
        events = []
        @test respond!(agent, "start"; on_event=identity, on_agent_event=event -> push!(events, event)) == "recovered"
        @test !isfile(joinpath(dir, "a.txt"))
        @test occursin("output token limit", provider.requests[2][end]["content"])
        @test only(event for event in events if event.type == :tool_execution_end).iserror
    end
end

@testset "agent cancellation and busy state" begin
    mktempdir() do dir
        calls = [call("one", "write", (; path="a.txt", content="first")), call("two", "write", (; path="b.txt", content="second"))]
        provider = AgentFixture([completion(nothing; calls, finish="tool_calls"), completion("next")], [])
        agent = Agent(provider, [Write(dir)])
        events = []
        busy = []
        result = respond!(agent, "start"; on_event=identity, on_agent_event=event -> begin
            push!(events, event)
            event.type == :agent_start && push!(busy, respond!(agent, "overlap"; on_event=identity))
            event.type == :agent_end && push!(busy, respond!(agent, "overlap"; on_event=identity))
            event.type == :tool_execution_end && event.tool_call_id == "one" && JuliaForever.cancel!(agent)
        end)
        @test result == :cancelled
        @test busy == [:busy, :busy]
        @test isfile(joinpath(dir, "a.txt"))
        @test !isfile(joinpath(dir, "b.txt"))
        @test [message["tool_call_id"] for message in agent.messages if message["role"] == "tool"] == ["one", "two"]
        @test occursin("cancelled", agent.messages[end]["content"])
        @test length(provider.requests) == 1
        @test respond!(agent, "continue"; on_event=identity) == "next"
        @test !JuliaForever.cancel!(agent)
    end
end

@testset "incomplete agent stream" begin
    provider = AgentFixture([completion("partial"; done=false, finish=nothing)], [])
    agent = Agent(provider, [])
    events = []
    result = respond!(agent, "start"; on_event=identity, on_agent_event=event -> push!(events, event))
    @test !result.done
    @test [message["role"] for message in agent.messages] == ["user"]
    @test last(events).type == :agent_end
end

mutable struct ConcurrentTool <: JuliaForever.Tool
    release::Channel{Nothing}
end

JuliaForever.name(::ConcurrentTool) = "ordered"
function JuliaForever.execute(tool::ConcurrentTool, args)
    if args.value == "first"
        take!(tool.release)
    end
    ToolResult(String(args.value))
end

@testset "parallel tool event and transcript order" begin
    calls = [call("one", "ordered", (; value="first")), call("two", "ordered", (; value="second"))]
    provider = AgentFixture([completion(nothing; calls, finish="tool_calls"), completion("done")], [])
    tool = ConcurrentTool(Channel{Nothing}(1))
    agent = Agent(provider, [tool])
    events = []
    @test respond!(agent, "start"; on_event=identity, tool_execution=:parallel, on_agent_event=event -> begin
        push!(events, event)
        event.type == :tool_execution_end && event.tool_call_id == "two" && put!(tool.release, nothing)
    end) == "done"
    @test [event.tool_call_id for event in events if event.type == :tool_execution_start] == ["one", "two"]
    @test [event.tool_call_id for event in events if event.type == :tool_execution_end] == ["two", "one"]
    @test [event.message["tool_call_id"] for event in events if event.type == :message_end && event.message["role"] == "tool"] == ["one", "two"]
    @test [message["tool_call_id"] for message in provider.requests[2] if message["role"] == "tool"] == ["one", "two"]
end

function JuliaForever.complete(provider::AgentFixture, messages, tools; parameters=Dict())
    push!(provider.requests, deepcopy(messages))
    popfirst!(provider.replies)
end

@testset "nonstreaming truncated tool calls" begin
    mktempdir() do dir
        calls = [call("one", "write", (; path="a.txt", content="partial"))]
        provider = AgentFixture([completion(nothing; calls, finish="length"), completion("done")], [])
        agent = Agent(provider, [Write(dir)])
        @test respond!(agent, "start") == "done"
        @test !isfile(joinpath(dir, "a.txt"))
        @test occursin("output token limit", provider.requests[2][end]["content"])
    end
end

mutable struct ChunkFixture
    replies::Vector{Completion}
end

function JuliaForever.stream(provider::ChunkFixture, messages, tools; parameters=Dict(), on_event=identity)
    result = popfirst!(provider.replies)
    if haskey(result.message, "tool_calls")
        on_event((; type=:tool_call, index=0, id="one", name="write", arguments="{\"path\":\"a"))
        on_event((; type=:tool_call, index=0, id=nothing, name=nothing, arguments=".txt\",\"content\":\"ok\"}"))
    else
        on_event((; type=:text, text="do"))
        on_event((; type=:text, text="ne"))
    end
    on_event((; type=:done, result))
    result
end

@testset "streamed lifecycle snapshots" begin
    mktempdir() do dir
        calls = [call("one", "write", (; path="a.txt", content="ok"))]
        provider = ChunkFixture([completion(nothing; calls, finish="tool_calls"), completion("done")])
        agent = Agent(provider, [Write(dir)])
        events = []
        raw = []
        @test respond!(agent, "start"; on_event=event -> push!(raw, event.type), on_agent_event=event -> push!(events, event)) == "done"
        updates = [event.message for event in events if event.type == :message_update]
        @test updates[1]["tool_calls"][1]["function"]["arguments"] == "{\"path\":\"a"
        @test JSON3.read(updates[2]["tool_calls"][1]["function"]["arguments"]).content == "ok"
        @test [updates[3]["content"], updates[4]["content"]] == ["do", "done"]
        @test raw == [:tool_call, :tool_call, :done, :text, :text, :done]
        @test read(joinpath(dir, "a.txt"), String) == "ok"
    end
end

struct FailingFixture end
function JuliaForever.stream(::FailingFixture, messages, tools; parameters=Dict(), on_event=identity)
    throw(ArgumentError("provider failed"))
end

@testset "provider failure releases the agent" begin
    agent = Agent(FailingFixture(), [])
    events = []
    @test_throws ArgumentError respond!(agent, "start"; on_event=identity, on_agent_event=event -> push!(events, event.type))
    @test events == [:agent_start, :turn_start, :message_start, :message_end, :agent_end]
    @test !agent.running
    @test !JuliaForever.cancel!(agent)
end

@testset "existing agent constructor" begin
    provider = AgentFixture(Completion[], [])
    tools = Dict{String, JuliaForever.Tool}()
    messages = Dict{String, Any}[Dict("role" => "user", "content" => "existing")]
    agent = Agent(provider, tools, messages)
    @test agent.messages === messages
    @test agent.tools === tools
end

@testset "malformed tool calls remain tool errors" begin
    calls = [Dict("id" => "missing"), Dict("id" => "null", "function" => nothing), Dict("id" => "args", "function" => Dict("name" => "write"))]
    provider = AgentFixture([completion(nothing; calls, finish="tool_calls"), completion("recovered")], [])
    agent = Agent(provider, [])
    @test respond!(agent, "start"; on_event=identity) == "recovered"
    results = [message for message in provider.requests[2] if message["role"] == "tool"]
    @test [message["tool_call_id"] for message in results] == ["missing", "null", "args"]
    @test all(message -> startswith(message["content"], "Error:"), results)
end
