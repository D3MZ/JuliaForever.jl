using Test, JuliaForever, Base64

@testset "dispatch preserves image results and history" begin
    image = Image("image/png", base64encode(read(joinpath(@__DIR__, "fixtures", "pixel.png"))))
    call = JuliaForever.Conversation.ToolCall("call", "read", "{}")
    for (result, failed) in ((ToolSuccess("ok", image), false), (ToolFailure("failed", image), true))
        @test result isa ToolResult
        @test result.iserror == failed
        @test isequal(result.image, image)
        @test typeof(ToolResult(result.text, failed, image)) === typeof(result)
        reply = JuliaForever.Conversation.ToolReply(result)
        @test reply.text == result.text && reply.iserror == failed && isequal(reply.image, image)
        message = JuliaForever.Conversation.ToolMessage(call, reply)
        @test message.content == (failed ? "Error: failed" : "ok")
        @test isequal(message.image, image)
        wire = JuliaForever.toolmessage(Dict("id" => "call"), result)
        @test wire["content"] == message.content
        @test wire["image"] == Dict("mime" => image.mime, "data" => image.data)
        event = JuliaForever.Kernel.Observe(2, "call", reply)
        record = JuliaForever.History.encode(event)
        decoded = JuliaForever.History.decode_event(record)
        @test isequal(decoded.observation.image, image)
        @test JuliaForever.History.encode(decoded) == record
    end
    for failed in (false, true)
        record = Dict{String, Any}("format" => "JuliaForever.AgentEvent/1", "event" => Dict{String, Any}("kind" => "observe", "fields" => Any[2, "call", Dict{String, Any}("kind" => "tool_reply", "fields" => Any["old", failed])]))
        decoded = JuliaForever.History.decode_event(record)
        @test decoded.observation.result isa (failed ? ToolFailure : ToolSuccess)
        @test decoded.observation.image === nothing
        @test JuliaForever.History.encode(decoded) == record
    end
end

@testset "terminal and plugin result dispatch" begin
    diagnostics = IOBuffer()
    terminal = JuliaForever.Terminal(IOBuffer(), diagnostics, String[])
    @test JuliaForever.pluginfailure!(terminal, "fixture", InterruptException()) == 130
    @test String(take!(diagnostics)) == "Request interrupted.\n"
    registry = JuliaForever.Extensions.Registry()
    @test JuliaForever.registered(terminal, registry, "fixture", true) === registry
    @test JuliaForever.registered(terminal, registry, "fixture", JuliaForever.Extensions.Rejected(:duplicate_tool, "x")) == 2
    @test occursin("duplicate_tool x", String(take!(diagnostics)))
    output = IOBuffer()
    @test JuliaForever.interact!(terminal, Agent(nothing, []), JuliaForever.Extensions.snapshot(registry), IOBuffer("/exit\n"), output) == 0
    @test isempty(String(take!(output)))
end
