using Test, JuliaForever, JSON3

@testset "Pi context estimate" begin
    source = ENV["PI_SOURCE"]
    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    c = JuliaForever.Conversation
    est = JuliaForever.ContextEstimates
    args = Dict("path" => "é😀.jl", "count" => 4)
    call = c.ToolCall("call", "read", JSON3.write(args))
    image = Image("image/png", "not-image-data")
    tool = Dict("name" => "read", "description" => "Read", "parameters" => Dict("type" => "object"))
    system = Dict{String, Any}("role" => "system", "content" => "guide 😀", "sections" => Dict("project" => "héllo", "unused" => nothing), "toolsAdded" => [tool])
    user = c.User("a😀界\nhello")
    assistant = c.Assistant("done", [call], "tool_calls", true; metadata=Dict("reasoning_content" => "think 🚀"))
    result = c.ToolMessage("call", "found", false, image)
    rich = c.RawMessage(Dict{String, Any}("role" => "user", "content" => [Dict("type" => "text", "text" => "more😀"), Dict("type" => "image_url", "image_url" => Dict("url" => "data:image/png;base64,ignored"))]))
    native = c.Message[c.RawMessage(system), user, assistant, result, rich]
    usage = (; input=70, output=20, cacheRead=8, cacheWrite=2, totalTokens=100)
    no_usage = (; input=0, output=0, cacheRead=0, cacheWrite=0, totalTokens=0)
    pi_system = merge(system, Dict("timestamp" => 0))
    pi_user = (; role="user", content=user.content, timestamp=1)
    pi_assistant = (; role="assistant", content=[(; type="text", text="done"), (; type="thinking", thinking="think 🚀"), (; type="toolCall", id="call", name="read", arguments=args)], timestamp=2, stopReason="toolUse", usage=no_usage)
    pi_result = (; role="toolResult", toolCallId="call", toolName="read", content=[(; type="text", text="found"), (; type="image", data="ignored", mimeType="image/png")], timestamp=3)
    pi_rich = (; role="user", content=[(; type="text", text="more😀"), (; type="image", data="ignored", mimeType="image/png")], timestamp=4)
    pi_plain = [pi_system, pi_user, pi_assistant, pi_result, pi_rich]
    pi_measured = [pi_system, pi_user, merge(pi_assistant, (; usage)), pi_result, pi_rich]
    pi_stale = [(; role="user", content="summary", timestamp=200), merge(pi_assistant, (; timestamp=100, usage)), (; role="user", content="tail 😀", timestamp=300)]
    native_stale = c.Message[c.User("summary"), assistant, c.User("tail 😀")]
    pi_fallback = [pi_system, pi_user, merge(pi_assistant, (; usage=merge(usage, (; totalTokens=0)))), pi_result, pi_rich]
    reader = Read(pwd())
    readerdecl = (; name=JuliaForever.name(reader), description=JuliaForever.description(reader), parameters=JuliaForever.schema(reader))
    with_tools = [Dict("role" => "system", "content" => "header", "timestamp" => 0, "toolsAdded" => [readerdecl]), pi_user]
    native_tools = c.Message[c.RawMessage(Dict{String, Any}("role" => "system", "content" => "header")), user]
    system_blocks = [(; type="text", text="first😀"), (; type="image", data="ignored", mimeType="image/png"), (; type="text", text="last")]
    pi_system_blocks = [Dict("role" => "system", "content" => system_blocks, "sections" => nothing, "timestamp" => 0)]
    native_system_blocks = c.Message[c.RawMessage(Dict{String, Any}("role" => "system", "content" => [Dict("type" => "text", "text" => "first😀"), Dict("type" => "image", "data" => "ignored"), Dict("type" => "text", "text" => "last")], "sections" => nothing))]
    arguments = [("x", "{\"x\":1e-6}", 1e-6), ("x", "{\"x\":100000000000000000000}", 1e20), ("fives", "{\"x\":99999999999999999}", 99999999999999999), ("x", "{\"x\":-0.0}", -0.0), ("x", "{\"x\":1e21}", 1e21), ("x", "{\"x\":1e-7}", 1e-7), ("x", "{\"x\":  \n  1}", 1)]
    native_arguments = [c.Assistant(nothing, [c.ToolCall("n", name, raw)], "tool_calls", true) for (name, raw, _) in arguments]
    pi_arguments = [[(; role="assistant", content=[(; type="toolCall", id="n", name, arguments=Dict("x" => value))], timestamp=0, stopReason="toolUse", usage=no_usage)] for (name, _, value) in arguments]
    aliases = [(Dict("reasoning" => "fall😀"), "fall😀"), (Dict("reasoning_text" => "texto"), "texto"), (Dict("reasoning_content" => "", "reasoning" => "é😀", "reasoning_text" => "ignored"), "é😀"), (Dict("reasoning_content" => Dict("unexpected" => true), "reasoning" => "優"), "優"), (Dict("reasoning_content" => "first", "reasoning" => "much longer alternative"), "first")]
    native_aliases = [c.Assistant("a", c.ToolCall[], "stop", true; metadata) for (metadata, _) in aliases]
    pi_aliases = [[(; role="assistant", content=[(; type="text", text="a"), (; type="thinking", thinking)], timestamp=0, stopReason="stop", usage=no_usage)] for (_, thinking) in aliases]
    cases = [pi_plain, pi_measured, pi_stale, pi_fallback, with_tools, pi_system_blocks, pi_arguments..., pi_aliases...]

    mktempdir() do dir
        fixture = joinpath(dir, "contexts.json")
        write(fixture, JSON3.write(cases))
        oracle = JSON3.read(read(`node $(joinpath(@__DIR__, "estimates_reference.mjs")) $source $fixture`, String))
        @test [est.tokens(message) for message in native] == oracle[1].messages
        @test [est.tokens(message) for message in native_stale] == oracle[3].messages
        for (actual, reference) in ((est.estimate(native), oracle[1].context), (est.estimate(native, 3 => Usage(70, 20, 8, 2, 0, 100, nothing)), oracle[2].context), (est.estimate(native_stale), oracle[3].context), (est.estimate(native, 3 => Usage(70, 20, 8, 2, 0, 0, nothing)), oracle[4].context))
            @test actual.total == reference.tokens
            @test actual.reported == reference.usageTokens
            @test actual.trailing == reference.trailingTokens
            @test actual.index == (isnothing(reference.lastUsageIndex) ? nothing : reference.lastUsageIndex + 1)
        end
        @test est.estimate(native_tools; tools=[reader]).total == oracle[5].context.tokens
        @test est.estimate(native_system_blocks).total == oracle[6].context.tokens
        # Native tool-call arguments retain their original JSON spelling.
        @test est.tokens.(native_arguments) == [4, 8, 8, 4, 4, 4, 4]
        @test [oracle[index].messages[1] for index in 7:13] == [5, 8, 9, 3, 4, 4, 3]
        @test est.tokens.(native_aliases) == [oracle[index].messages[1] for index in 14:18]
    end
end
