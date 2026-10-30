using JuliaForever, JSON3

function fixturestream(provider, messages, tools, on_event)
    scenario = get(ENV, "JF_JSON_SCENARIO", "text")
    scenario == "noisy" && println("provider diagnostic")
    user = messages[end]["role"] == "user"
    if scenario in ("tool", "badargs") && user
        arguments = scenario == "tool" ? "{\"path\":\"sample.txt\"}" : "{broken"
        call = Dict("id" => "call-1", "type" => "function", "function" => Dict("name" => "read", "arguments" => arguments))
        on_event((; type=:text, text="Before "))
        initial = scenario == "tool" ? "{\"path\":" : arguments
        on_event((; type=:tool_call, index=0, id="call-1", name="read", arguments=initial))
        scenario == "tool" && on_event((; type=:tool_call, index=0, id=nothing, name=nothing, arguments="\"sample.txt\"}"))
        return Completion(Dict{String, Any}("role" => "assistant", "content" => "Before ", "tool_calls" => [call]), Usage(3, 2, 0, 0, 0, 5, nothing), "tool_calls", true, nothing)
    end
    if scenario == "incomplete"
        on_event((; type=:text, text="partial"))
        return Completion(Dict{String, Any}("role" => "assistant", "content" => "partial"), nothing, "incomplete", false, "fixture-key")
    end
    if scenario == "thinking"
        on_event((; type=:thinking, text="consider", field="reasoning_content"))
        on_event((; type=:text, text="answer"))
        return Completion(Dict{String, Any}("role" => "assistant", "content" => "answer", "reasoning_content" => "consider"), nothing, "stop", true, nothing)
    end
    if scenario == "reconcile"
        on_event((; type=:text, text="draft"))
        return Completion(Dict{String, Any}("role" => "assistant", "content" => "final"), nothing, "stop", true, nothing)
    end
    text = scenario in ("tool", "badargs") ? "after" : "reply:" * messages[end]["content"]
    on_event((; type=:text, text))
    on_event((; type=:usage, usage=Usage(3, 2, 0, 0, 0, 5, nothing)))
    Completion(Dict{String, Any}("role" => "assistant", "content" => text), Usage(3, 2, 0, 0, 0, 5, nothing), "stop", true, nothing)
end

for provider in (OpenAI, OpenAIResponses, Anthropic, Google)
    @eval JuliaForever.stream(provider::$provider, messages, tools; parameters=Dict(), on_event=identity) = fixturestream(provider, messages, tools, on_event)
end

exit(JuliaForever.main(ARGS))
