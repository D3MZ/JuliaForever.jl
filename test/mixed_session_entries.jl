module MixedSessionEntriesTests

using Test, JuliaForever, JSON3, Base64
import JuliaForever as J

struct Provider
    model::String
end
function J.complete(::Provider, messages, tools; parameters=Dict())
    text = get(last(messages), "content", "")
    if get(last(messages), "role", "") == "user" && text in ("tool", "tool-image")
        path = text == "tool" ? "target.txt" : "target.png"
        id = text == "tool" ? "read-1" : "read-image"
        call = Dict("id" => id, "type" => "function", "function" => Dict("name" => "read", "arguments" => JSON3.write((; path))))
        return Completion(Dict{String, Any}("role" => "assistant", "content" => nothing, "tool_calls" => [call]), nothing, "tool_calls", true, nothing)
    end
    Completion(Dict{String, Any}("role" => "assistant", "content" => "answer"), nothing, "stop", true, nothing)
end
function J.stream(provider::Provider, messages, tools; parameters=Dict(), on_event=identity)
    result = J.complete(provider, messages, tools; parameters)
    on_event((; type=:text, text="answer"))
    on_event((; type=:done, result))
    result
end

end
