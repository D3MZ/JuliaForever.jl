module AbandonTests

using Test, JuliaForever
import JuliaForever.History as H
import JuliaForever.Kernel as K
import JuliaForever.Conversation as C

mutable struct StrictProvider
    requests::Vector{Any}
end

function JuliaForever.complete(provider::StrictProvider, messages, tools)
    push!(provider.requests, deepcopy(messages))
    assistant = only(message for message in messages if message["role"] == "assistant")
    expected = [call["id"] for call in assistant["tool_calls"]]
    actual = [message["tool_call_id"] for message in messages if message["role"] == "tool"]
    @test actual == expected
    @test [message["role"] for message in messages] == ["user", "assistant", "tool", "tool", "tool", "user"]
    Dict{String, Any}("role" => "assistant", "content" => "done")
end

end
