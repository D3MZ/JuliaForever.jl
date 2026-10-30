module BeforeToolCases
using Test, JuliaForever, JSON3
const E = JuliaForever.Extensions
mutable struct Provider
    replies::Vector{Any}
    requests::Vector{Any}
end
function JuliaForever.complete(p::Provider, messages, tools)
    push!(p.requests, deepcopy(messages)); popfirst!(p.replies)
end
struct Echo <: JuliaForever.Tool end
JuliaForever.name(::Echo) = "echo"
JuliaForever.description(::Echo) = "echo"
JuliaForever.schema(::Echo) = Dict("type" => "object", "properties" => Dict())
JuliaForever.execute(::Echo, args) = ToolResult(args.value)
@testset "before tool interception" begin
    reference = nothing
    if haskey(ENV, "PI_SOURCE")
        source = ENV["PI_SOURCE"]
        @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
        reference = JSON3.read(read(`node $(joinpath(@__DIR__, "before_tool_reference.mjs")) $source`, String))
    end
    for history in (nothing, JuliaForever.History.Memory()), mode in (:transform, :block, :error)
        seen = Any[]
        reg = E.Registry()
        E.register!(reg, :first, E.Plugin(; tools=(Echo(),), hooks=(:tool_call => (e -> begin
            push!(seen, e.input["value"]); e.input["value"] = "changed"
            mode == :error && error("broken")
            mode == :block ? E.Block("denied") : nothing
        end),)))
        E.register!(reg, :second, E.Plugin(; hooks=(:tool_call => (e -> (push!(seen, e.input["value"]); nothing)), :tool_result => (e -> (push!(seen, e.result.text); nothing)))))
        listener = E.listen(E.snapshot(reg))
        call = Dict("id" => "1", "type" => "function", "function" => Dict("name" => "echo", "arguments" => "{\"value\":\"original\"}"))
        p = Provider([Dict("role" => "assistant", "content" => nothing, "tool_calls" => [call]), Dict("role" => "assistant", "content" => "done")], [])
        @test respond!(Agent(p, E.snapshot(reg); history), "go"; on_agent_event=listener) == "done"
        if !isnothing(reference)
            expected = reference[string(mode)]
            @test seen[1:length(expected.seen)] == expected.seen
            @test mode == :transform ? expected.value == "changed" : expected.reason == (mode == :block ? "denied" : "broken")
        end
        @test seen == (mode == :transform ? ["original", "changed", "changed"] : ["original"])
        @test p.requests[2][end]["content"] == (mode == :transform ? "changed" : mode == :block ? "Error: denied" : "Error: broken")
    end
end
mutable struct StreamProvider
    replies::Vector{Any}
    requests::Vector{Any}
end
function JuliaForever.stream(p::StreamProvider, messages, tools; parameters=Dict(), on_event=identity)
    push!(p.requests, deepcopy(messages))
    result = popfirst!(p.replies)
    on_event((; type=:done, result))
    result
end

@testset "terminal before tool, result hook and shell updates" begin
    for history in (nothing, JuliaForever.History.Memory()), mode in (:transform, :block)
        events = Any[]
        reg = E.Registry()
        E.register!(reg, :hooks, E.Plugin(; hooks=(:tool_call => (e -> begin
            e.input["command"] = "printf changed"
            mode == :block ? E.Block("denied") : nothing
        end), :tool_result => (e -> ToolResult(e.result.text * "-result")))))
        snapshot = E.snapshot(reg)
        call = Dict("id" => "1", "type" => "function", "function" => Dict("name" => "bash", "arguments" => "{\"command\":\"printf original\"}"))
        reply = Dict{String, Any}("role" => "assistant", "content" => nothing, "tool_calls" => [call])
        done = Dict{String, Any}("role" => "assistant", "content" => "done")
        p = StreamProvider([Completion(reply, nothing, "tool_calls", true, nothing), Completion(done, nothing, "stop", true, nothing)], [])
        terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), String[])
        @test JuliaForever.run!(terminal, Agent(p, [Bash(pwd())]; history), "go", snapshot; on_agent_event=e -> push!(events, e)) == 0
        @test p.requests[2][end]["content"] == (mode == :block ? "Error: denied" : "changed-result")
        if mode == :transform
            @test any(e -> e.type == :tool_execution_update, events)
        end
    end
end

@testset "before-tool hooks retain Unicode arguments" begin
    value = "unicode " * string(Char(0x10ffff))
    reg = E.Registry()
    E.register!(reg, :hooks, E.Plugin(; tools=(Echo(),), hooks=(:tool_call => (event -> (event.input["value"] *= "!"; nothing)),)))
    snapshot = E.snapshot(reg)
    call = Dict("id" => "unicode", "type" => "function", "function" => Dict("name" => "echo", "arguments" => JSON3.write((; value))))
    provider = Provider([Dict("role" => "assistant", "content" => nothing, "tool_calls" => [call]), Dict("role" => "assistant", "content" => "done")], [])
    @test respond!(Agent(provider, snapshot), "go"; on_agent_event=E.listen(snapshot)) == "done"
    @test provider.requests[2][end]["content"] == value * "!"
    execution = JuliaForever.Execution
    conversation = JuliaForever.Conversation
    context = "unicode-before-tool-test"
    @test execution.install!(context, nothing, [Echo()])
    try
        request = conversation.ToolRequest(conversation.ToolCall("unicode", "echo", JSON3.write((; value))))
        reply = execution.perform(execution.Work(context, request), execution.Cancellation())
        @test reply.text == value
    finally
        execution.uninstall!(context)
    end
end

@testset "continuation combines call hooks and deferred discovery" begin
    for history in (nothing, JuliaForever.History.Memory())
        reg = E.Registry()
        E.register!(reg, :hooks, E.Plugin(; hooks=(
            :tool_call => (event -> begin
                event.tool_name == "tool_search" && (event.input["query"] = "echo")
                event.tool_name == "echo" && (event.input["value"] = "prepared")
                nothing
            end),
            :tool_result => (event -> event.tool_name == "tool_search" ? ToolResult("search replaced") : ToolResult("after " * event.result.text)),
        )))
        snapshot = E.snapshot(reg)
        search = Dict("id" => "search", "type" => "function", "function" => Dict("name" => "tool_search", "arguments" => "{\"query\":\"missing\"}"))
        echo = Dict("id" => "echo", "type" => "function", "function" => Dict("name" => "echo", "arguments" => "{\"value\":\"original\"}"))
        replies = Any[Dict("role" => "assistant", "content" => nothing, "tool_calls" => [call]) for call in (search, echo)]
        push!(replies, Dict("role" => "assistant", "content" => "done"))
        provider = Provider(replies, [])
        tools = ToolSet([], [Echo()])
        agent = Agent(provider, tools, [Dict{String, Any}("role" => "user", "content" => "find")]; history)
        @test continue!(agent; on_agent_event=E.listen(snapshot)) == "done"
        @test provider.requests[2][end]["content"] == "search replaced"
        @test provider.requests[3][end]["content"] == "after prepared"
        if history !== nothing
            restored = Agent(provider, tools; history)
            @test "echo" in keys(restored.tools)
            @test restored.messages == agent.messages
        end
    end
end

end
