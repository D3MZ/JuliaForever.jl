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
    if mode == "markdown"
        first = "# Demo\n\nHello **bo"
        second = "ld** and *italic*.\n\n- first\n- second\n\n```julia\nx = 1\n```\n\n| Name | Count |\n| --- | --- |\n| α | 2 |\n\nSafe \e]2;spoof\a text."
        on_event((; type=:text, text=first))
        while !isfile(joinpath(ENV["JF_INSTRUCTIONS_DIR"], "release"))
            sleep(0.05)
        end
        on_event((; type=:text, text=second))
        return Completion(Dict{String, Any}("role" => "assistant", "content" => first * second), nothing, "stop", true, nothing)
    end
    if mode == "hold" && messages[end]["role"] == "user" && messages[end]["content"] == "hold"
        on_event((; type=:text, text="Holding"))
        while !isfile(joinpath(ENV["JF_INSTRUCTIONS_DIR"], "release"))
            sleep(0.05)
        end
    end
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
    if mode == "length"
        on_event((; type=:text, text="partial"))
        on_event((; type=:text, text=" content"))
        return Completion(Dict{String, Any}("role" => "assistant", "content" => "partial content"), nothing, "length", true, nothing)
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
