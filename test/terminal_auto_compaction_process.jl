using JuliaForever, JSON3

function record(operation, messages)
    open(ENV["JF_AUTO_REQUESTS"], "a") do io
        println(io, JSON3.write((; operation, messages)))
    end
end

function JuliaForever.complete(provider::OpenAI, messages, tools; parameters=Dict())
    record("summarize", messages)
    gate = get(ENV, "JF_AUTO_GATE", "")
    if !isempty(gate)
        while !isfile(gate)
            sleep(0.02)
        end
    end
    usage = Usage(20, 5, 0, 0, 0, 25, 0.001)
    finish = get(ENV, "JF_AUTO_SUMMARY", "") == "fail" ? "length" : "stop"
    Completion(Dict{String, Any}("role" => "assistant", "content" => "checkpoint"), usage, finish, true, nothing)
end

function JuliaForever.stream(provider::OpenAI, messages, tools; parameters=Dict(), on_event=identity)
    record("respond", messages)
    text = messages[end]["content"]
    compacted = any(message -> occursin("<summary>", string(get(message, "content", ""))), messages)
    if text == "overflow" && !compacted
        return Completion(Dict{String, Any}("role" => "assistant", "content" => "partial"), nothing, nothing, false, ProviderStatus(413))
    end
    result = "reply:" * text
    on_event((; type=:text, text=result))
    tokens = get(Dict("first" => 130, "second" => 131), text, 50)
    Completion(Dict{String, Any}("role" => "assistant", "content" => result), Usage(tokens, 0, 0, 0, 0, tokens, 0.01), "stop", true, nothing)
end

exit(JuliaForever.main(ARGS))
