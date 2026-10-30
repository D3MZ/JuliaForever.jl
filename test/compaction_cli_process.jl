using JuliaForever, JSON3

function record(operation, messages, tools)
    open(ENV["JF_COMPACTION_REQUESTS"], "a") do io
        println(io, JSON3.write((; operation, messages, tool_count=length(tools))))
    end
end

function JuliaForever.complete(provider::OpenAI, messages, tools; parameters=Dict())
    record("summarize", messages, tools)
    Completion(Dict{String, Any}("role" => "assistant", "content" => "checkpoint"), nothing, "stop", true, nothing)
end

function JuliaForever.stream(provider::OpenAI, messages, tools; parameters=Dict(), on_event=identity)
    record("respond", messages, tools)
    text = "reply:" * messages[end]["content"]
    on_event((; type=:text, text))
    Completion(Dict{String, Any}("role" => "assistant", "content" => text), nothing, "stop", true, nothing)
end

exit(JuliaForever.main(ARGS))
