using JuliaForever, JSON3, HTTP

function JuliaForever.stream(provider::OpenAI, messages, tools; parameters=Dict(), on_event=identity)
    mode = ENV["JF_FIXTURE"]
    if haskey(ENV, "JF_CAPTURE")
        open(ENV["JF_CAPTURE"], "a") do io
            println(io, JSON3.write(messages[end]["content"]))
        end
    end
    mode == "http" && throw(HTTP.StatusError(HTTP.Response(401)))
    mode == "json" && JSON3.read("{bad fixture}")
    mode == "bug" && throw(ArgumentError("ordinary failure"))
    if mode in ("plugin", "codeplugin", "two-plugins")
        haskey(tools, "greet") || error("greet tool not exposed")
        mode == "two-plugins" && !haskey(tools, "farewell") && error("farewell tool not exposed")
        JuliaForever.definition(tools["greet"])["function"]["description"] == "Greet a person" || error("greet metadata missing")
        if messages[end]["role"] == "user"
            name = mode == "codeplugin" ? "codemode" : "greet"
            arguments = mode == "codeplugin" ? (; code="text(tools.greet((; name=\"Ada\")).text)") : (; name="Ada")
            call = Dict("id" => "one", "type" => "function", "function" => Dict("name" => name, "arguments" => JSON3.write(arguments)))
            return Completion(Dict{String, Any}("role" => "assistant", "content" => "Before", "tool_calls" => [call]), nothing, "stop", true, nothing)
        end
        text = "plugin:" * messages[end]["content"]
        return Completion(Dict{String, Any}("role" => "assistant", "content" => text), nothing, "stop", true, nothing)
    end
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
