using Test, JuliaForever

const CT = JuliaForever.ContextEstimates
const EC = JuliaForever.Conversation

@testset "context estimates" begin
    @test CT.tokens("") == 0
    @test CT.tokens("abcdefg") == 2
    @test CT.tokens("😀😀") == 2
    @test CT.tokens("e\u0301界") == 1

    user = EC.User("a😀界")
    call = EC.ToolCall("c", "read", "{\"path\":\"x😀\"}")
    assistant = EC.Assistant("ok", [call], "tool_calls", true; metadata=Dict("reasoning_content" => "考"))
    result = EC.ToolMessage("c", "done", false, Image("image/png", "synthetic"))
    system = EC.RawMessage(Dict{String, Any}("role" => "system", "content" => "guide"))
    messages = EC.Message[system, user, assistant, result]

    @test CT.tokens(user) == 2
    @test CT.tokens(result) == 1373
    @test CT.tokens(assistant) == CT.tokens("ok考read{\"path\":\"x😀\"}")
    initial = CT.estimate(messages)
    @test initial.total == sum(CT.tokens, messages)
    @test initial.reported == 0 && initial.trailing == initial.total && initial.index === nothing

    usage = Usage(70, 20, 8, 2, 3, 100, nothing)
    anchored = CT.estimate(messages, 3 => usage)
    @test anchored.total == 100 + CT.tokens(result)
    @test (anchored.reported, anchored.trailing, anchored.index) == (100, CT.tokens(result), 3)
    @test CT.estimate(messages, 3 => Usage(70, 20, 8, 2, 3, 0, nothing)).reported == 100
    @test CT.estimate(messages, 3 => Usage(0, 0, 0, 0, 0, 0, nothing)) == initial
    @test_throws BoundsError CT.estimate(messages, 0 => usage)
    @test_throws BoundsError CT.estimate(messages, 5 => usage)

    reader = Read(pwd())
    @test CT.estimate(messages; tools=[reader]).total > initial.total
    @test CT.estimate(messages, 3 => usage; tools=[reader]) == anchored
    @test CT.estimate(EC.Message[]; tools=()).total == 0
    @test CT.estimate(messages; tools=Dict("read" => reader)) == CT.estimate(messages; tools=[reader])
    rawassistant = EC.RawMessage(Dict{String, Any}("role" => "assistant", "content" => "ok", "reasoning_content" => "考", "tool_calls" => [Dict("function" => Dict("name" => "read", "arguments" => "{\"path\":\"x😀\"}"))]))
    rawtool = EC.RawMessage(Dict{String, Any}("role" => "tool", "content" => "done", "image" => Dict("mime" => "image/png", "data" => "ignored")))
    @test CT.tokens(rawassistant) == CT.tokens(assistant)
    @test CT.tokens(rawtool) == CT.tokens(result)
    empty_sections = EC.RawMessage(Dict{String, Any}("role" => "system", "content" => "abc", "sections" => nothing))
    @test CT.tokens(empty_sections) == CT.tokens("abc")
    @test_throws KeyError CT.tokens(EC.RawMessage(Dict{String, Any}("role" => "developer", "content" => "hi")))
    @test_throws KeyError CT.tokens(EC.RawMessage(Dict{String, Any}("role" => "user", "content" => [Dict("type" => "file")])))

    # Stored native messages carry neither authoritative usage nor timestamps.
    # An arbitrary metadata field must not be treated as a trusted measurement.
    spoofed = EC.Assistant("ok", EC.ToolCall[], "stop", true; metadata=Dict("usage" => Dict("total_tokens" => 5000), "timestamp" => 10))
    @test CT.estimate(EC.Message[spoofed]).reported == 0
    @test CT.estimate(EC.Message[spoofed]).index === nothing

    malformed = EC.Assistant(nothing, [EC.ToolCall("c", "read", "{\"x\":")], "length", false)
    @test CT.tokens(malformed) == CT.tokens("read{\"x\":")
end
