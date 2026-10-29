using JuliaForever, JSON3, HTTP

function JuliaForever.stream(provider::OpenAI, messages, tools; parameters=Dict(), on_event=identity)
    mode = ENV["JF_FIXTURE"]
    mode == "http" && throw(HTTP.StatusError(HTTP.Response(401)))
    mode == "json" && JSON3.read("{bad fixture}")
    mode == "bug" && throw(ArgumentError("ordinary failure"))
    if mode == "incomplete"
        on_event((; type=:text, text="partial"))
        return Completion(Dict{String, Any}("role" => "assistant", "content" => "partial"), nothing, nothing, false, "synthetic-secret")
    end
    first = mode == "tool" && messages[end]["role"] == "user"
    text = first ? "Before" : mode == "tool" ? "after" : "reply:" * messages[end]["content"]
    on_event((; type=:text, text))
    message = Dict{String, Any}("role" => "assistant", "content" => text)
    if first
        call = Dict("id" => "one", "type" => "function", "function" => Dict("name" => "read", "arguments" => JSON3.write((; path="missing-synthetic-secret"))))
        message["tool_calls"] = [call]
    end
    Completion(message, nothing, "stop", true, nothing)
end

exit(JuliaForever.main(ARGS))
