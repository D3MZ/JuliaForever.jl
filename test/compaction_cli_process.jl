using JuliaForever, JSON3

function record(operation, messages)
    open(ENV["JF_COMPACTION_REQUESTS"], "a") do io
        println(io, JSON3.write((; operation, messages)))
    end
end

function JuliaForever.complete(provider::OpenAI, messages, tools; parameters=Dict())
    record("summarize", messages)
    Completion(Dict{String, Any}("role" => "assistant", "content" => "checkpoint"), nothing, "stop", true, nothing)
end

function JuliaForever.stream(provider::OpenAI, messages, tools; parameters=Dict(), on_event=identity)
    record("respond", messages)
    text = "reply:" * messages[end]["content"]
    on_event((; type=:text, text))
    Completion(Dict{String, Any}("role" => "assistant", "content" => text), nothing, "stop", true, nothing)
end

exit(JuliaForever.main(ARGS))
